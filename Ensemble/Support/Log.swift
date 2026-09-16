import Foundation
import os

/// Tiny logging shim: writes to the unified log and to stdout (useful when the
/// binary is launched from a terminal for testing).
enum Log {
    private static let logger = Logger(subsystem: "com.ashinno.ensemble", category: "app")
    static let verbose: Bool = {
        setvbuf(stdout, nil, _IOLBF, 0) // line-buffered stdout so logs survive when launched from a terminal
        return CommandLine.arguments.contains("-verbose")
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[\(formatter.string(from: Date()))] \(message)"); fflush(stdout)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        print("[\(formatter.string(from: Date()))] ERROR: \(message)"); fflush(stdout)
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        print("[\(formatter.string(from: Date()))] debug: \(message())"); fflush(stdout)
    }
}
