import AppKit
import Foundation
import OSLog

let logger = Logger(subsystem: "com.stevenha.MacPearl.CameraBroker", category: "lifecycle")
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let broker = CameraBroker()
let listener = BrokerListener(broker: broker)
listener.start()
broker.start()
logger.info("MacPearl camera broker running")
application.run()
