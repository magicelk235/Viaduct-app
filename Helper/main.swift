import Foundation

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "agent": HelperAgent.run()
default:
    FileHandle.standardError.write(Data("usage: ViaductHelper agent\n".utf8))
    exit(64)
}
