import Foundation

public struct ParserRegistry: Sendable {
    public static let slackBundleID = "com.tinyspeck.slackmacgap"
    private let parsers: [String: any SourceParser]

    public init() {
        parsers = [Self.slackBundleID: SlackParser()]
    }

    public func parser(for bundleID: String) -> (any SourceParser)? {
        parsers[bundleID]
    }
}
