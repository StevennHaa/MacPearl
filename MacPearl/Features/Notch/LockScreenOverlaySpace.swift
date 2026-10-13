import AppKit
import OSLog

/// Optional private window-server integration for lock-screen presentation.
/// ABI reference: jonnyoo/glance's NotchSkyLight and Lakr233/SkyLightWindow.
/// Resolving symbols dynamically allows normal unlocking if support is absent.
@MainActor
final class LockScreenOverlaySpace {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias Level = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias Spaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias Attach = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias Detach = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let library: UnsafeMutableRawPointer
    private let connection: Int32
    private let space: Int32
    private let attachWindows: Attach
    private let detachWindows: Detach
    private let logger = Logger(subsystem: "com.stevenha.MacPearl", category: "notch-overlay")

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW | RTLD_LOCAL) else { return nil }
        let names = ["SLSMainConnectionID", "SLSSpaceCreate", "SLSSpaceSetAbsoluteLevel", "SLSShowSpaces", "SLSSpaceAddWindowsAndRemoveFromSpaces", "SLSRemoveWindowsFromSpaces"]
        let symbols = names.compactMap { dlsym(handle, $0) }
        guard symbols.count == names.count else { dlclose(handle); return nil }
        let connection = unsafeBitCast(symbols[0], to: Connection.self)()
        let space = unsafeBitCast(symbols[1], to: Create.self)(connection, 1, 0)
        guard connection != 0, space != 0 else { dlclose(handle); return nil }
        // Notification Center's lock-screen space level, matching the ABI
        // reference. This changes only our dedicated presentation space.
        _ = unsafeBitCast(symbols[2], to: Level.self)(connection, space, 400)
        _ = unsafeBitCast(symbols[3], to: Spaces.self)(connection, [NSNumber(value: space)] as CFArray)
        library = handle
        self.connection = connection
        self.space = space
        attachWindows = unsafeBitCast(symbols[4], to: Attach.self)
        detachWindows = unsafeBitCast(symbols[5], to: Detach.self)
    }

    func attach(_ window: NSWindow) -> Bool {
        guard LockSessionMonitor.currentLockState() == true else { return false }
        let result = attachWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        if result != 0 { logger.notice("Lock-screen overlay unavailable: \(result)") }
        return result == 0
    }

    func detach(_ window: NSWindow) {
        _ = detachWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }
}
