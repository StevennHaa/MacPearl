import Foundation

@objc protocol MacPearlCameraBrokerProtocol {
    func health(reply: @escaping (NSDictionary) -> Void)
    func beginLockedScreenProbe(nonce: NSData, reply: @escaping (NSDictionary) -> Void)
    func cancelProbe(nonce: NSData)
}

enum BrokerOutcome: Int {
    case frameReceived = 0
    case permissionUnavailable = 1
    case noCamera = 2
    case configurationFailed = 3
    case timedOut = 4
    case cancelled = 5
    case staleFrame = 6
}

enum BrokerWire {
    static let protocolVersion = 1
    static let maximumFrameAge: TimeInterval = 2

    static func response(
        outcome: BrokerOutcome,
        authorizationStatus: Int,
        deviceCount: Int = 0,
        deviceType: String = "",
        deviceHash: String = "",
        latencyMilliseconds: Double = -1,
        nonce: Data = Data()
    ) -> NSDictionary {
        [
            "version": protocolVersion,
            "outcome": outcome.rawValue,
            "authorizationStatus": authorizationStatus,
            "deviceCount": deviceCount,
            "deviceType": deviceType,
            "deviceHash": deviceHash,
            "latencyMilliseconds": latencyMilliseconds,
            "nonce": nonce,
            "generatedAt": Date().timeIntervalSince1970,
        ]
    }
}
