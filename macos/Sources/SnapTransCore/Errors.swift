import Foundation

/// An error whose user-facing text is chosen by the UI (`code` = string table key suffix "Err_<code>"), same codes as Windows.
public struct SnapTransError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let args: [String]
    public init(_ code: String, _ args: Any...) { self.code = code; self.args = args.map { "\($0)" } }
    public var description: String { args.isEmpty ? code : code + " " + args.joined(separator: " ") }
}

/// Errors that can be logged without leaking paths or text (code + short safe arguments only).
public protocol SnapTransErrorLike { var safeDescription: String { get } }
extension SnapTransError: SnapTransErrorLike {
    public var safeDescription: String {
        let safe = args.map { a in a.count <= 40 && a.range(of: #"^[A-Za-z0-9 ._:+-]*$"#, options: .regularExpression) != nil ? a : "?" }
        return safe.isEmpty ? code : code + " " + safe.joined(separator: " ")
    }
}
