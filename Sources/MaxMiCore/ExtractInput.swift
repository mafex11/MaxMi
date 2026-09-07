public struct ExtractMetadata: Sendable, Equatable {
    public let sourceApp: String
    public let sourceKey: String
    public let title: String?
    public let url: String?
    public let kind: CaptureContentKind
    public let capturedAt: EpochMs

    public init(
        sourceApp: String,
        sourceKey: String,
        title: String?,
        url: String?,
        kind: CaptureContentKind,
        capturedAt: EpochMs
    ) {
        self.sourceApp = sourceApp
        self.sourceKey = sourceKey
        self.title = title
        self.url = url
        self.kind = kind
        self.capturedAt = capturedAt
    }
}

public struct ExtractInput: Sendable, Equatable {
    public let newContent: String
    public let previousContent: String?
    public let metadata: ExtractMetadata

    public init(newContent: String, previousContent: String?, metadata: ExtractMetadata) {
        self.newContent = newContent
        self.previousContent = previousContent
        self.metadata = metadata
    }
}

public enum ExtractInputBuilder {
    public static let maxNewContentChars = 20_000

    public static func build(
        delta: CaptureDelta,
        previousStructured: CapturedContent?,
        metadata: ExtractMetadata
    ) -> ExtractInput {
        ExtractInput(
            newContent: CaptureDeltaRenderer.render(delta, maxChars: maxNewContentChars),
            previousContent: previousStructured.map {
                ContentRenderer.render($0, style: .compact(maxChars: 2_000))
            },
            metadata: metadata
        )
    }
}
