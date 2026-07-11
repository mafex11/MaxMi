public struct ActionItemDTO: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let details: String?
    public let status: String
    public let timeAgo: String

    public init(id: String, title: String, details: String?, status: String, timeAgo: String) {
        self.id = id
        self.title = title
        self.details = details
        self.status = status
        self.timeAgo = timeAgo
    }
}
