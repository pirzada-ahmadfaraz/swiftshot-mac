import Foundation
import os.log

enum Log {
    static let general = OSLog(subsystem: "com.ahmadfaraz.cleanshotclone", category: "general")
    static let capture = OSLog(subsystem: "com.ahmadfaraz.cleanshotclone", category: "capture")
    static let recording = OSLog(subsystem: "com.ahmadfaraz.cleanshotclone", category: "recording")

    static func info(_ message: String, log: OSLog = general) {
        os_log("%{public}@", log: log, type: .info, message)
    }

    static func error(_ message: String, log: OSLog = general) {
        os_log("%{public}@", log: log, type: .error, message)
    }
}
