import Foundation
import OSLog
import NordicMesh

/// Unified logging for Amaranth. Everything goes through the macOS unified
/// logging system under the `so.kel.Amaranth` subsystem, so we can stream
/// or replay logs with `log show` / `log stream`.
///
/// Pull recent logs:
///     log show --predicate 'subsystem == "so.kel.Amaranth"' --info --debug --last 5m
/// Tail live:
///     log stream --predicate 'subsystem == "so.kel.Amaranth"' --level=debug
enum Log {
    static let subsystem = "so.kel.Amaranth"
    static let app       = Logger(subsystem: subsystem, category: "app")
    static let importer  = Logger(subsystem: subsystem, category: "import")
    static let scanner   = Logger(subsystem: subsystem, category: "scanner")
    static let bearer    = Logger(subsystem: subsystem, category: "bearer")
    static let mesh      = Logger(subsystem: subsystem, category: "mesh")
    static let send      = Logger(subsystem: subsystem, category: "send")
    static let recv      = Logger(subsystem: subsystem, category: "recv")
}

/// Bridges NordicMesh's internal `LoggerDelegate` to os.Logger so library
/// traffic (encryption, segmentation, retransmits, proxy filter changes,
/// bearer state) ends up in the same unified log.
final class OSLogMeshLogger: LoggerDelegate {
    static let shared = OSLogMeshLogger()

    func log(message: String, ofCategory category: LogCategory, withLevel level: LogLevel) {
        let logger = Logger(subsystem: Log.subsystem, category: "mesh.\(category.rawValue)")
        switch level {
        case .debug:       logger.debug("\(message, privacy: .public)")
        case .verbose:     logger.debug("\(message, privacy: .public)")
        case .info:        logger.info("\(message, privacy: .public)")
        case .application: logger.notice("\(message, privacy: .public)")
        case .warning:     logger.warning("\(message, privacy: .public)")
        case .error:       logger.error("\(message, privacy: .public)")
        }
    }
}
