import XCTest
@testable import Viaduct

final class HelperAgentTests: XCTestCase {
    private func makeApp(withPersist: Bool) throws -> URL {
        let contents = TempDir.make().appendingPathComponent("Viaduct.app/Contents")
        var files = ["Helpers/ViaductHelper", "Resources/bin/node"]
        if withPersist { files.append("Resources/firefox/persist.mjs") }
        for file in files.map(contents.appendingPathComponent) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        return contents
    }

    func testFindsNodeAndPersistInsideItsOwnApp() throws {
        let contents = try makeApp(withPersist: true)
        let runtime = try XCTUnwrap(HelperAgent.bundledRuntime(helperURL: contents.appendingPathComponent("Helpers/ViaductHelper")))
        XCTAssertEqual(runtime.node.path, contents.appendingPathComponent("Resources/bin/node").path)
        XCTAssertEqual(runtime.persist.path, contents.appendingPathComponent("Resources/firefox/persist.mjs").path)
    }

    func testNoRuntimeWhenPersistIsMissing() throws {
        let contents = try makeApp(withPersist: false)
        XCTAssertNil(HelperAgent.bundledRuntime(helperURL: contents.appendingPathComponent("Helpers/ViaductHelper")))
    }
}
