import Darwin
import Foundation
import MacPearlAuthCtlCore

private func usage() -> Never {
    FileHandle.standardError.write(Data("usage: macpearl-authctl check <plugin> | install-diagnostic <plugin> | status | uninstall\n".utf8))
    exit(64)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { usage() }
    let installer = AuthCtlInstaller(runner: ProcessCommandRunner())
    switch command {
    case "check":
        guard arguments.count == 2 else { usage() }
        try installer.check(plugin: URL(fileURLWithPath: arguments[1]))
        print("Plug-in signature, identity, and entry point are valid.")
    case "install-diagnostic":
        guard arguments.count == 2 else { usage() }
        guard geteuid() == 0 else { throw AuthCtlError.rootRequired }
        try installer.installDiagnostic(plugin: URL(fileURLWithPath: arguments[1]))
        print("Diagnostic CameraProbe policy installed. It always denies authorization.")
    case "status":
        guard arguments.count == 1 else { usage() }
        guard geteuid() == 0 else { throw AuthCtlError.rootRequired }
        print(installer.status())
    case "uninstall":
        guard arguments.count == 1 else { usage() }
        guard geteuid() == 0 else { throw AuthCtlError.rootRequired }
        try installer.uninstall()
        print("Original authorization policy restored and diagnostic plug-in removed.")
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("macpearl-authctl: \(error.localizedDescription)\n".utf8))
    exit(1)
}
