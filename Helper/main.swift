import Foundation

let args = Array(CommandLine.arguments.dropFirst())

// Firefox starts the native host with its own arguments, not a subcommand.
if NativeHostProtocol.isLaunchedByFirefox(arguments: args) { NativeHost.run() }

switch args.first {
case "agent": HelperAgent.run()
default:
    FileHandle.standardError.write(Data("usage: ViaductHelper agent\n".utf8))
    exit(64)
}
