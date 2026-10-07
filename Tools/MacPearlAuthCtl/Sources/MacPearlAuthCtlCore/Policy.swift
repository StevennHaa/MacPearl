import Foundation

public enum PolicyError: LocalizedError, Equatable {
    case invalidPropertyList
    case unsupportedScreenSaverPolicy

    public var errorDescription: String? {
        switch self {
        case .invalidPropertyList: "Authorization right is not a property-list dictionary."
        case .unsupportedScreenSaverPolicy: "system.login.screensaver does not contain use-login-window-ui; refusing an unsafe rewrite."
        }
    }
}

public enum DiagnosticPolicy {
    public static let rightName = "com.stevenha.MacPearl.camera-probe"
    public static let mechanism = "MacPearlAuthorizationPlugin:CameraProbe"
    public static let loginWindowRule = "use-login-window-ui"

    public static var right: [String: Any] {
        [
            "class": "evaluate-mechanisms",
            "mechanisms": [mechanism],
            "tries": 1,
            "version": 1,
            "comment": "MacPearl diagnostic camera probe; always denies",
        ]
    }

    public static func installedScreenSaverPolicy(from data: Data) throws -> [String: Any] {
        guard var policy = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw PolicyError.invalidPropertyList
        }
        guard let rules = policy["rule"] as? [String], rules.contains(loginWindowRule) else {
            throw PolicyError.unsupportedScreenSaverPolicy
        }
        policy["class"] = "rule"
        policy["rule"] = [rightName, loginWindowRule]
        policy["k-of-n"] = 1
        return policy
    }

    public static func plistData(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
}
