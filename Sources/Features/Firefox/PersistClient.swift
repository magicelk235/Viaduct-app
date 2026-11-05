import Foundation

/// What persist answers after an install or uninstall.
struct PersistResult: Decodable, Equatable {
    let id, name, version, profilePath: String
    /// True when the add-on only arrives the next time Firefox starts.
    let pending: Bool
}

/// One add-on persist keeps loading, as `persist list` reports it.
struct PersistAddon: Decodable, Equatable {
    let id, name, version, profilePath, dir, firefox: String
}

struct PersistStatus: Decodable, Equatable {
    struct Agent: Decodable, Equatable { let running: Bool; let pid: Int? }
    struct Profile: Decodable, Equatable { let profilePath: String; let lastLoad: Date?; let lastError: String? }
    let agent: Agent
    let profiles: [Profile]
}

struct PersistProfiles: Decodable, Equatable {
    struct Firefox: Decodable, Equatable { let channel, version, path: String }
    struct Profile: Decodable, Equatable, Identifiable {
        let name, path: String
        let isDefault, inUse: Bool
        var id: String { path }
    }
    let firefoxes: [Firefox]
    let profiles: [Profile]
}

enum PersistError: LocalizedError, Equatable {
    case runtimeMissing
    case failed(String)
    case unreadableOutput(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            return "Firefox support is missing from this copy of Viaduct. Download Viaduct again."
        case .failed(let message):
            return message
        case .unreadableOutput(let raw):
            let sentence = "Viaduct couldn't read Firefox's answer."
            return raw.isEmpty ? sentence : sentence + "\n" + raw
        }
    }
}

protocol PersistClientProtocol: Sendable {
    func install(staged: URL, profile: String?, firefox: String, restart: Bool, launch: Bool) async throws -> PersistResult
    func uninstall(id: String, profile: String?, restart: Bool) async throws -> PersistResult
    func list() async throws -> [PersistAddon]
    func status() async throws -> PersistStatus
    func profiles(firefox: String?) async throws -> PersistProfiles
}

/// Runs the bundled persist.mjs on the bundled node and reads its JSON answers.
struct PersistClient: PersistClientProtocol {
    private let log: @Sendable (String) -> Void

    /// `log` gets persist's stderr lines during install and uninstall,
    /// on a background thread.
    init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
    }

    static var scriptURL: URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("firefox/persist.mjs", isDirectory: false) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Persist writes dates with `toISOString()`, which has milliseconds the
    /// stock `.iso8601` strategy rejects.
    static let decoder: JSONDecoder = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }()

    // MARK: - Arguments

    static func installArguments(staged: URL, profile: String?, firefox: String, restart: Bool, launch: Bool) -> [String] {
        var args = ["install", staged.path]
        if let profile { args += ["--profile", profile] }
        args += ["--firefox", firefox, "--json"]
        if !restart { args.append("--no-firefox-restart") }
        if !launch { args.append("--no-launch") }
        return args
    }

    static func uninstallArguments(id: String, profile: String?, restart: Bool) -> [String] {
        var args = ["uninstall", id]
        if let profile { args += ["--profile", profile] }
        args.append("--json")
        if !restart { args.append("--no-firefox-restart") }
        return args
    }

    /// The app owns the launch agent, so persist must never write or load its own.
    static func environment(base: [String: String]) -> [String: String] {
        var env = base
        env["LAVADUCT_PERSIST_AGENT"] = "external"
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extra + ":" + (base["PATH"] ?? "")
        return env
    }

    // MARK: - Decoding

    private struct Outcome: Decodable {
        let ok: Bool
        let error: String?
    }

    private struct AddonList: Decodable {
        let addons: [PersistAddon]
    }

    /// Reads install/uninstall's answer from the last line of stdout. Only an
    /// explicit `"ok":true` counts as success.
    static func decodeOutcome(_ stdout: Data) throws -> PersistResult {
        let text = String(decoding: stdout, as: UTF8.self)
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = text.split(whereSeparator: \.isNewline)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
            let outcome = try? decoder.decode(Outcome.self, from: Data(line.utf8))
        else { throw PersistError.unreadableOutput(raw) }

        guard outcome.ok else {
            guard let message = outcome.error else { throw PersistError.unreadableOutput(raw) }
            throw PersistError.failed(message)
        }
        guard let result = try? decoder.decode(PersistResult.self, from: Data(line.utf8)) else {
            throw PersistError.unreadableOutput(raw)
        }
        return result
    }

    static func decodeList(_ stdout: Data) throws -> [PersistAddon] {
        try decode(AddonList.self, from: stdout).addons
    }

    private static func decode<T: Decodable>(_ type: T.Type, from stdout: Data) throws -> T {
        do {
            return try decoder.decode(type, from: stdout)
        } catch {
            let raw = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PersistError.unreadableOutput(raw)
        }
    }

    // MARK: - Commands

    func install(staged: URL, profile: String?, firefox: String, restart: Bool, launch: Bool) async throws -> PersistResult {
        let args = Self.installArguments(staged: staged, profile: profile, firefox: firefox, restart: restart, launch: launch)
        // Exit 1 carries `"ok":false` with persist's own message, so the
        // status code alone says nothing useful.
        return try Self.decodeOutcome(try await run(args, streamLog: true).stdout)
    }

    func uninstall(id: String, profile: String?, restart: Bool) async throws -> PersistResult {
        let args = Self.uninstallArguments(id: id, profile: profile, restart: restart)
        return try Self.decodeOutcome(try await run(args, streamLog: true).stdout)
    }

    func list() async throws -> [PersistAddon] {
        try Self.decodeList(try await query(["list", "--json"]))
    }

    func status() async throws -> PersistStatus {
        try Self.decode(PersistStatus.self, from: try await query(["status", "--json"]))
    }

    func profiles(firefox: String?) async throws -> PersistProfiles {
        var args = ["profiles", "--json"]
        if let firefox { args += ["--firefox", firefox] }
        return try Self.decode(PersistProfiles.self, from: try await query(args))
    }

    /// Runs a read-only command and returns its stdout, or throws when it failed.
    private func query(_ arguments: [String]) async throws -> Data {
        let result = try await run(arguments, streamLog: false)
        guard result.status == 0 else {
            throw PersistError.failed(result.lastError ?? "Firefox support stopped with code \(result.status).")
        }
        return result.stdout
    }

    // MARK: - Process

    /// Holds stdout while another thread reads stderr.
    private final class Collected: @unchecked Sendable {
        var data = Data()
    }

    private func run(_ arguments: [String], streamLog: Bool) async throws -> (status: Int32, stdout: Data, lastError: String?) {
        guard let node = CLIRunner.resolveNode(), let script = Self.scriptURL else {
            throw PersistError.runtimeMissing
        }
        let log = self.log

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = node
                process.arguments = [script.path] + arguments
                process.environment = Self.environment(base: ProcessInfo.processInfo.environment)
                process.currentDirectoryURL = script.deletingLastPathComponent()
                process.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: PersistError.runtimeMissing)
                    return
                }

                // Read both pipes at once: persist blocks for good if the one
                // nobody reads fills up.
                let stdout = Collected()
                let reading = DispatchGroup()
                reading.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdout.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    reading.leave()
                }

                var lastError: String?
                func take(_ bytes: Data) {
                    let line = String(decoding: bytes, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { return }
                    if streamLog { log(line) }
                    if line.hasPrefix("✗") {
                        let message = line.dropFirst().trimmingCharacters(in: .whitespaces)
                        if !message.isEmpty { lastError = message }
                    }
                }

                let errHandle = errPipe.fileHandleForReading
                var pending = Data()
                while case let chunk = errHandle.availableData, !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        take(pending[pending.startIndex..<newline])
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
                take(pending)

                reading.wait()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, stdout.data, lastError))
            }
        }
    }
}
