import Foundation

enum RuntimeMode {
    static var demo: Bool {
        CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["WODUE_DEMO"] == "1"
    }
}
