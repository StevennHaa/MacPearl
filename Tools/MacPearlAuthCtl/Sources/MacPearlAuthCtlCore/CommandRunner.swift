import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], stdin: Data?) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], stdin: Data?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: output.fileHandleForReading.readDataToEndOfFile(),
            stderr: errors.fileHandleForReading.readDataToEndOfFile()
        )
    }
}
