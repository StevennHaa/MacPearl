import Foundation
import Testing
@testable import MacPearlAuthCtlCore

@Test func policyPreservesMetadataAndKeepsLoginWindowFallback() throws {
    let original: [String: Any] = [
        "class": "rule",
        "rule": ["authenticate-session-owner-or-admin", "use-login-window-ui"],
        "shared": true,
        "version": 7,
    ]
    let result = try DiagnosticPolicy.installedScreenSaverPolicy(from: DiagnosticPolicy.plistData(original))
    #expect(result["rule"] as? [String] == [DiagnosticPolicy.rightName, DiagnosticPolicy.loginWindowRule])
    #expect(result["k-of-n"] as? Int == 1)
    #expect(result["shared"] as? Bool == true)
    #expect(result["version"] as? Int == 7)
}

@Test func policyRefusesUnknownShapeWithoutLoginWindowFallback() throws {
    let original = ["class": "rule", "rule": ["authenticate-session-owner"]] as [String: Any]
    #expect(throws: PolicyError.unsupportedScreenSaverPolicy) {
        try DiagnosticPolicy.installedScreenSaverPolicy(from: DiagnosticPolicy.plistData(original))
    }
}

private final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call { let executable: String; let arguments: [String]; let stdin: Data? }
    var calls: [Call] = []
    var screenSaver: Data
    var customRight: Data?
    var failScreenSaverWrite = false

    init(screenSaver: Data, customRight: Data? = nil) {
        self.screenSaver = screenSaver
        self.customRight = customRight
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, stdin: stdin))
        if executable == "/usr/bin/codesign", arguments.first == "--verify" { return CommandResult(status: 0) }
        if executable == "/usr/bin/codesign" {
            let identifier = arguments.last?.contains("CameraBroker") == true
                ? AuthCtlInstaller.expectedBrokerIdentifier
                : AuthCtlInstaller.expectedIdentifier
            return CommandResult(status: 0, stderr: Data("Identifier=\(identifier)\nTeamIdentifier=\(AuthCtlInstaller.expectedTeamID)\n".utf8))
        }
        if executable == "/usr/bin/nm" { return CommandResult(status: 0, stdout: Data("_AuthorizationPluginCreate\n".utf8)) }
        if executable == "/usr/sbin/chown" || executable == "/bin/chmod" { return CommandResult(status: 0) }
        if executable == "/bin/launchctl" { return CommandResult(status: 0) }
        if executable == "/usr/bin/stat" {
            let output = arguments.last == "/dev/console" ? "501\n" : "501 600\n"
            return CommandResult(status: 0, stdout: Data(output.utf8))
        }
        if arguments == ["authorizationdb", "read", AuthCtlInstaller.screenSaverRight] { return CommandResult(status: 0, stdout: screenSaver) }
        if arguments == ["authorizationdb", "read", DiagnosticPolicy.rightName] {
            return customRight.map { CommandResult(status: 0, stdout: $0) } ?? CommandResult(status: 1)
        }
        if arguments == ["authorizationdb", "write", AuthCtlInstaller.screenSaverRight] {
            if failScreenSaverWrite { failScreenSaverWrite = false; return CommandResult(status: 1, stderr: Data("injected".utf8)) }
            screenSaver = stdin!
            return CommandResult(status: 0)
        }
        if arguments == ["authorizationdb", "write", DiagnosticPolicy.rightName] { customRight = stdin!; return CommandResult(status: 0) }
        if arguments == ["authorizationdb", "remove", DiagnosticPolicy.rightName] { customRight = nil; return CommandResult(status: 0) }
        return CommandResult(status: 1, stderr: Data("unexpected command".utf8))
    }
}

private func temporaryPaths() throws -> (URL, AuthCtlPaths) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = AuthCtlPaths(
        pluginDestination: root.appendingPathComponent("Plugins/MacPearlAuthorizationPlugin.bundle"),
        brokerDestination: root.appendingPathComponent("Applications/MacPearlCameraBroker.app"),
        launchAgentDestination: root.appendingPathComponent("LaunchAgents/com.stevenha.MacPearl.CameraBroker.plist"),
        stateDirectory: root.appendingPathComponent("State")
    )
    try FileManager.default.createDirectory(at: paths.brokerDestination, withIntermediateDirectories: true)
    return (root, paths)
}

private func fakePlugin(at root: URL) throws -> URL {
    let plugin = root.appendingPathComponent("Build/MacPearlAuthorizationPlugin.bundle")
    try FileManager.default.createDirectory(at: plugin.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try Data().write(to: plugin.appendingPathComponent("Contents/MacOS/MacPearlAuthorizationPlugin"))
    return plugin
}

@Test func installAndUninstallRoundTripRestoresExactRights() throws {
    let originalScreen = try DiagnosticPolicy.plistData(["class": "rule", "rule": ["use-login-window-ui"], "version": 9])
    let originalCustom = try DiagnosticPolicy.plistData(["class": "allow"])
    let runner = FakeRunner(screenSaver: originalScreen, customRight: originalCustom)
    let (root, paths) = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = AuthCtlInstaller(runner: runner, paths: paths)
    try installer.installDiagnostic(plugin: fakePlugin(at: root))
    #expect(FileManager.default.fileExists(atPath: paths.pluginDestination.path))
    #expect(runner.screenSaver != originalScreen)
    try installer.uninstall()
    #expect(runner.screenSaver == originalScreen)
    #expect(runner.customRight == originalCustom)
    #expect(!FileManager.default.fileExists(atPath: paths.pluginDestination.path))
}

@Test func failedPolicyWriteRollsBackRightsAndPlugin() throws {
    let originalScreen = try DiagnosticPolicy.plistData(["class": "rule", "rule": ["use-login-window-ui"]])
    let runner = FakeRunner(screenSaver: originalScreen)
    runner.failScreenSaverWrite = true
    let (root, paths) = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = AuthCtlInstaller(runner: runner, paths: paths)
    #expect(throws: (any Error).self) { try installer.installDiagnostic(plugin: fakePlugin(at: root)) }
    #expect(runner.screenSaver == originalScreen)
    #expect(runner.customRight == nil)
    #expect(!FileManager.default.fileExists(atPath: paths.pluginDestination.path))
}

@Test func existingDestinationIsNeverRemoved() throws {
    let originalScreen = try DiagnosticPolicy.plistData(["class": "rule", "rule": ["use-login-window-ui"]])
    let runner = FakeRunner(screenSaver: originalScreen)
    let (root, paths) = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: paths.pluginDestination, withIntermediateDirectories: true)
    let marker = paths.pluginDestination.appendingPathComponent("owner-marker")
    try Data("existing".utf8).write(to: marker)
    let installer = AuthCtlInstaller(runner: runner, paths: paths)
    #expect(throws: (any Error).self) { try installer.installDiagnostic(plugin: fakePlugin(at: root)) }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(runner.calls.isEmpty)
}

@Test func diagnosticInstallRequiresBroker() throws {
    let originalScreen = try DiagnosticPolicy.plistData(["class": "rule", "rule": ["use-login-window-ui"]])
    let runner = FakeRunner(screenSaver: originalScreen)
    let (root, paths) = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: paths.brokerDestination)
    let installer = AuthCtlInstaller(runner: runner, paths: paths)
    #expect(throws: (any Error).self) { try installer.installDiagnostic(plugin: fakePlugin(at: root)) }
    #expect(runner.calls.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: paths.pluginDestination.path))
}

@Test func brokerInstallRefusesExistingDestination() throws {
    let originalScreen = try DiagnosticPolicy.plistData(["class": "rule", "rule": ["use-login-window-ui"]])
    let runner = FakeRunner(screenSaver: originalScreen)
    let (root, paths) = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = paths.brokerDestination.appendingPathComponent("owner-marker")
    try Data("existing".utf8).write(to: marker)
    let installer = AuthCtlInstaller(runner: runner, paths: paths)
    #expect(throws: (any Error).self) { try installer.installBroker(root.appendingPathComponent("Build/MacPearlCameraBroker.app")) }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(runner.calls.isEmpty)
}

@Test func brokerInstallCreatesAndBootstrapsLaunchAgent() throws {
    let originalScreen = try DiagnosticPolicy.plistData(["class": "rule", "rule": ["use-login-window-ui"]])
    let runner = FakeRunner(screenSaver: originalScreen)
    let (root, paths) = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: paths.brokerDestination)
    let source = root.appendingPathComponent("Build/MacPearlCameraBroker.app")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

    let installer = AuthCtlInstaller(runner: runner, paths: paths)
    try installer.installBroker(source)

    let launchAgent = try #require(paths.launchAgentDestination)
    let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: launchAgent), format: nil) as? [String: Any])
    #expect(plist["Label"] as? String == AuthCtlInstaller.expectedBrokerIdentifier)
    #expect((plist["MachServices"] as? [String: Bool])?[AuthCtlInstaller.expectedBrokerIdentifier] == true)
    #expect(runner.calls.contains { $0.executable == "/bin/launchctl" && $0.arguments.first == "bootstrap" })
    #expect(runner.calls.contains { $0.executable == "/bin/launchctl" && $0.arguments.first == "kickstart" })
    #expect(runner.calls.contains { $0.executable == "/bin/launchctl" && $0.arguments.first == "print" })
}
