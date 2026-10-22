import Foundation

enum ObjC {
    struct Exception: Error, CustomStringConvertible {
        let name: String
        let reason: String
        var description: String { "\(name): \(reason)" }
    }

    /// Runs `body`, turning an Objective-C exception into a Swift error.
    static func catching<T>(_ body: () -> T) throws -> T {
        var result: T?
        if let exception = PulsoCatchException({ result = body() }) {
            throw Exception(name: exception.name.rawValue, reason: exception.reason ?? "")
        }
        return result!
    }
}
