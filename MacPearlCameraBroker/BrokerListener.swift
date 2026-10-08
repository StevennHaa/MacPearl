import Foundation
import OSLog
import Darwin

final class BrokerListener: NSObject, NSXPCListenerDelegate {
    static let serviceName = "com.stevenha.MacPearl.CameraBroker"
    private let listener = NSXPCListener(machServiceName: serviceName)
    private let broker: CameraBroker
    private let logger = Logger(subsystem: "com.stevenha.MacPearl.CameraBroker", category: "ipc")

    init(broker: CameraBroker) {
        self.broker = broker
        super.init()
        listener.delegate = self
    }

    func start() {
        // SecurityAgentHelper is Apple-signed. The delegate additionally narrows
        // accepted peers to the expected host process name.
        listener.setConnectionCodeSigningRequirement("anchor apple")
        listener.activate()
        logger.info("Broker Mach service activated")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let processName = processNameForPID(connection.processIdentifier)
        guard processName.hasPrefix("SecurityAgentHelper") else {
            logger.error("Rejected XPC peer pid=\(connection.processIdentifier, privacy: .public) process=\(processName, privacy: .public)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: MacPearlCameraBrokerProtocol.self)
        connection.exportedObject = broker
        connection.activate()
        logger.info("Accepted SecurityAgent XPC peer")
        return true
    }

    private func processNameForPID(_ pid: pid_t) -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        _ = path // Keep validation independent of the caller's environment.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
