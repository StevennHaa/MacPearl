import CryptoKit
import Darwin
import Foundation

public struct AuthCtlPaths: Sendable {
    public var pluginDestination: URL
    public var brokerDestination: URL
    public var launchAgentDestination: URL?
    public var stateDirectory: URL

    public init(
        pluginDestination: URL = URL(fileURLWithPath: "/Library/Security/SecurityAgentPlugins/MacPearlAuthorizationPlugin.bundle"),
        brokerDestination: URL = URL(fileURLWithPath: "/Applications/MacPearlCameraBroker.app"),
        launchAgentDestination: URL? = nil,
        stateDirectory: URL = URL(fileURLWithPath: "/Library/Application Support/MacPearl")
    ) {
        self.pluginDestination = pluginDestination
        self.brokerDestination = brokerDestination
        self.launchAgentDestination = launchAgentDestination
        self.stateDirectory = stateDirectory
    }
}

public struct InstallManifest: Codable, Equatable, Sendable {
    public let installedAt: Date
    public let screenSaverSHA256: String
    public let customRightExisted: Bool
    public let customRightSHA256: String?
    public let backupDirectory: String
}

public enum AuthCtlError: LocalizedError {
    case commandFailed(String)
    case invalidSignature(String)
    case missingExport
    case alreadyInstalled
    case notInstalled
    case rootRequired

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .invalidSignature(let message): "Plug-in signature validation failed: \(message)"
        case .missingExport: "Plug-in does not export AuthorizationPluginCreate."
        case .alreadyInstalled: "An active MacPearl diagnostic installation already exists."
        case .notInstalled: "No active MacPearl diagnostic installation exists."
        case .rootRequired: "This command must be run as root."
        }
    }
}

public final class AuthCtlInstaller: @unchecked Sendable {
    public static let expectedIdentifier = "com.stevenha.MacPearl.AuthorizationPlugin"
    public static let expectedTeamID = "FY4JUG23QT"
    public static let expectedBrokerIdentifier = "com.stevenha.MacPearl.CameraBroker"
    public static let screenSaverRight = "system.login.screensaver"

    private let runner: CommandRunning
    private let files: FileManager
    public let paths: AuthCtlPaths
    private var manifestURL: URL { paths.stateDirectory.appendingPathComponent("active-install.json") }

    public init(runner: CommandRunning, paths: AuthCtlPaths = AuthCtlPaths(), files: FileManager = .default) {
        self.runner = runner
        self.paths = paths
        self.files = files
    }

    public func check(plugin: URL) throws {
        try checkSignedBundle(plugin, identifier: Self.expectedIdentifier)
        let symbols = try requireSuccess("/usr/bin/nm", ["-gj", plugin.appendingPathComponent("Contents/MacOS/MacPearlAuthorizationPlugin").path])
        guard String(decoding: symbols, as: UTF8.self).split(separator: "\n").contains("_AuthorizationPluginCreate") else {
            throw AuthCtlError.missingExport
        }
    }

    public func checkBroker(_ broker: URL) throws {
        try checkSignedBundle(broker, identifier: Self.expectedBrokerIdentifier)
    }

    public func installBroker(_ broker: URL) throws {
        guard !files.fileExists(atPath: paths.brokerDestination.path) else {
            throw AuthCtlError.commandFailed("Camera broker is already installed; refusing to overwrite it.")
        }
        let consoleUser = try consoleUser()
        let launchAgent = launchAgentURL(for: consoleUser)
        guard !files.fileExists(atPath: launchAgent.path) else {
            throw AuthCtlError.commandFailed("Camera broker LaunchAgent already exists; refusing to overwrite it.")
        }
        try checkBroker(broker)
        var ownsDestination = false
        var ownsLaunchAgent = false
        do {
            ownsDestination = true
            try files.copyItem(at: broker, to: paths.brokerDestination)
            _ = try requireSuccess("/usr/sbin/chown", ["-R", "root:wheel", paths.brokerDestination.path])
            _ = try requireSuccess("/bin/chmod", ["-R", "go-w", paths.brokerDestination.path])

            try files.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": Self.expectedBrokerIdentifier,
                "ProgramArguments": [paths.brokerDestination.appendingPathComponent("Contents/MacOS/MacPearlCameraBroker").path],
                "MachServices": [Self.expectedBrokerIdentifier: true],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            ownsLaunchAgent = true
            try plistData.write(to: launchAgent, options: .atomic)
            _ = try requireSuccess("/usr/sbin/chown", ["\(consoleUser.uid):\(consoleUser.gid)", launchAgent.path])
            _ = try requireSuccess("/bin/chmod", ["644", launchAgent.path])
            _ = try requireSuccess("/bin/launchctl", ["bootstrap", "gui/\(consoleUser.uid)", launchAgent.path])
            _ = try requireSuccess("/bin/launchctl", ["kickstart", "-k", "gui/\(consoleUser.uid)/\(Self.expectedBrokerIdentifier)"])
            try requireRunningBroker(for: consoleUser)
        } catch {
            _ = try? runner.run("/bin/launchctl", ["bootout", "gui/\(consoleUser.uid)/\(Self.expectedBrokerIdentifier)"], stdin: nil)
            if ownsLaunchAgent { try? files.removeItem(at: launchAgent) }
            if ownsDestination { try? files.removeItem(at: paths.brokerDestination) }
            throw error
        }
    }

    public func removeBroker() throws {
        let consoleUser = try consoleUser()
        let launchAgent = launchAgentURL(for: consoleUser)
        _ = try? runner.run("/bin/launchctl", ["bootout", "gui/\(consoleUser.uid)/\(Self.expectedBrokerIdentifier)"], stdin: nil)
        if files.fileExists(atPath: launchAgent.path) {
            try files.removeItem(at: launchAgent)
        }
        if files.fileExists(atPath: paths.brokerDestination.path) {
            try files.removeItem(at: paths.brokerDestination)
        }
    }

    public func installDiagnostic(plugin: URL) throws {
        guard !files.fileExists(atPath: manifestURL.path) else { throw AuthCtlError.alreadyInstalled }
        guard !files.fileExists(atPath: paths.pluginDestination.path) else {
            throw AuthCtlError.commandFailed("Destination plug-in already exists; refusing to overwrite it.")
        }
        guard files.fileExists(atPath: paths.brokerDestination.path) else {
            throw AuthCtlError.commandFailed("Install and start MacPearlCameraBroker before enabling the diagnostic policy.")
        }
        try checkBroker(paths.brokerDestination)
        try requireRunningBroker(for: consoleUser())
        try check(plugin: plugin)
        let screenSaver = try readRight(Self.screenSaverRight)
        let updated = try DiagnosticPolicy.installedScreenSaverPolicy(from: screenSaver)
        let custom = try readOptionalRight(DiagnosticPolicy.rightName)
        let backup = paths.stateDirectory.appendingPathComponent("AuthorizationBackups/\(Int(Date().timeIntervalSince1970))")
        try files.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try screenSaver.write(to: backup.appendingPathComponent("system.login.screensaver.plist"), options: .atomic)
        if let custom { try custom.write(to: backup.appendingPathComponent("custom-right.plist"), options: .atomic) }
        let manifest = InstallManifest(installedAt: Date(), screenSaverSHA256: sha256(screenSaver), customRightExisted: custom != nil, customRightSHA256: custom.map(sha256), backupDirectory: backup.path)

        var ownsDestination = false
        do {
            try files.createDirectory(at: paths.pluginDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            ownsDestination = true
            try files.copyItem(at: plugin, to: paths.pluginDestination)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.pluginDestination.path)
            _ = try requireSuccess("/usr/sbin/chown", ["-R", "root:wheel", paths.pluginDestination.path])
            _ = try requireSuccess("/bin/chmod", ["-R", "go-w", paths.pluginDestination.path])
            try writeRight(DiagnosticPolicy.rightName, value: DiagnosticPolicy.right)
            try writeRight(Self.screenSaverRight, value: updated)
            try files.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoded = try JSONEncoder().encode(manifest)
            try encoded.write(to: manifestURL, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch {
            try? restore(screenSaver: screenSaver, custom: custom)
            if ownsDestination { try? files.removeItem(at: paths.pluginDestination) }
            throw error
        }
    }

    public func uninstall() throws {
        guard files.fileExists(atPath: manifestURL.path) else { throw AuthCtlError.notInstalled }
        let manifest = try JSONDecoder().decode(InstallManifest.self, from: Data(contentsOf: manifestURL))
        let backup = URL(fileURLWithPath: manifest.backupDirectory)
        let screenSaver = try Data(contentsOf: backup.appendingPathComponent("system.login.screensaver.plist"))
        guard sha256(screenSaver) == manifest.screenSaverSHA256 else { throw AuthCtlError.commandFailed("Screen saver backup checksum mismatch.") }
        var custom: Data?
        if manifest.customRightExisted {
            custom = try Data(contentsOf: backup.appendingPathComponent("custom-right.plist"))
            guard custom.map(sha256) == manifest.customRightSHA256 else { throw AuthCtlError.commandFailed("Custom-right backup checksum mismatch.") }
        }
        try restore(screenSaver: screenSaver, custom: custom)
        if files.fileExists(atPath: paths.pluginDestination.path) { try files.removeItem(at: paths.pluginDestination) }
        try files.removeItem(at: manifestURL)
    }

    public func status() -> String {
        let manifest = files.fileExists(atPath: manifestURL.path)
        let plugin = files.fileExists(atPath: paths.pluginDestination.path)
        let broker = files.fileExists(atPath: paths.brokerDestination.path)
        return "manifest=\(manifest ? "present" : "absent") plugin=\(plugin ? "present" : "absent") broker=\(broker ? "present" : "absent")"
    }

    private func restore(screenSaver: Data, custom: Data?) throws {
        // Restore the login path first so a secondary-right failure cannot leave
        // the screen saver policy pointing at a diagnostic right.
        try writeRight(Self.screenSaverRight, data: screenSaver)
        if let custom { try writeRight(DiagnosticPolicy.rightName, data: custom) }
        else { _ = try? runner.run("/usr/bin/security", ["authorizationdb", "remove", DiagnosticPolicy.rightName], stdin: nil) }
    }

    private func readRight(_ name: String) throws -> Data {
        try requireSuccess("/usr/bin/security", ["authorizationdb", "read", name])
    }

    private func checkSignedBundle(_ bundle: URL, identifier: String) throws {
        try requireSuccess("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", bundle.path])
        let details = try requireSuccess("/usr/bin/codesign", ["-d", "--verbose=4", bundle.path], acceptStderr: true)
        let text = String(decoding: details, as: UTF8.self)
        guard text.contains("Identifier=\(identifier)") else { throw AuthCtlError.invalidSignature("unexpected bundle identifier") }
        guard text.contains("TeamIdentifier=\(Self.expectedTeamID)") else { throw AuthCtlError.invalidSignature("expected Apple Development Team \(Self.expectedTeamID)") }
    }

    private struct ConsoleUser {
        let uid: UInt32
        let gid: UInt32
        let home: String
    }

    private func consoleUser() throws -> ConsoleUser {
        let result = try runner.run("/usr/bin/stat", ["-f", "%u", "/dev/console"], stdin: nil)
        guard result.status == 0,
              let uid = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let numericUID = UInt32(uid), numericUID != 0,
              let record = getpwuid(uid_t(numericUID)) else {
            throw AuthCtlError.commandFailed("Could not determine the signed-in console user.")
        }
        return ConsoleUser(uid: numericUID, gid: UInt32(record.pointee.pw_gid), home: String(cString: record.pointee.pw_dir))
    }

    private func launchAgentURL(for user: ConsoleUser) -> URL {
        paths.launchAgentDestination ?? URL(fileURLWithPath: user.home)
            .appendingPathComponent("Library/LaunchAgents/\(Self.expectedBrokerIdentifier).plist")
    }

    private func requireRunningBroker(for user: ConsoleUser) throws {
        let result = try runner.run("/bin/launchctl", ["print", "gui/\(user.uid)/\(Self.expectedBrokerIdentifier)"], stdin: nil)
        guard result.status == 0 else {
            throw AuthCtlError.commandFailed("Camera broker LaunchAgent is not running for the signed-in user.")
        }
    }

    private func readOptionalRight(_ name: String) throws -> Data? {
        let result = try runner.run("/usr/bin/security", ["authorizationdb", "read", name], stdin: nil)
        return result.status == 0 ? result.stdout : nil
    }

    private func writeRight(_ name: String, value: Any) throws { try writeRight(name, data: DiagnosticPolicy.plistData(value)) }
    private func writeRight(_ name: String, data: Data) throws { _ = try requireSuccess("/usr/bin/security", ["authorizationdb", "write", name], stdin: data) }

    @discardableResult
    private func requireSuccess(_ executable: String, _ arguments: [String], stdin: Data? = nil, acceptStderr: Bool = false) throws -> Data {
        let result = try runner.run(executable, arguments, stdin: stdin)
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self)
            throw AuthCtlError.commandFailed("\(executable) failed: \(message)")
        }
        return acceptStderr ? result.stdout + result.stderr : result.stdout
    }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
