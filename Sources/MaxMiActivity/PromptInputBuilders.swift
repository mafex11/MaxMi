import Foundation
import MaxMiCore

public struct CaptureSummaryPromptInput: Sendable, Equatable {
    public enum Variant: Sendable, Equatable {
        case action
        case conversation
    }

    public let variant: Variant
    public let appLabel: String
    public let sourceTitle: String?
    public let url: String?
    public let kind: CaptureContentKind
    public let capturedAtISO8601: String
    public let trigger: CaptureTrigger
    public let onScreenMain: String
    public let renderedDelta: String
    public let typedText: String
    public let channel: String?
    public let isGroup: Bool?
    public let hasMeaningfulContent: Bool

    public init(
        variant: Variant,
        appLabel: String,
        sourceTitle: String?,
        url: String?,
        kind: CaptureContentKind,
        capturedAtISO8601: String,
        trigger: CaptureTrigger,
        onScreenMain: String,
        renderedDelta: String,
        typedText: String,
        channel: String?,
        isGroup: Bool?,
        hasMeaningfulContent: Bool
    ) {
        self.variant = variant
        self.appLabel = appLabel
        self.sourceTitle = sourceTitle
        self.url = url
        self.kind = kind
        self.capturedAtISO8601 = capturedAtISO8601
        self.trigger = trigger
        self.onScreenMain = onScreenMain
        self.renderedDelta = renderedDelta
        self.typedText = typedText
        self.channel = channel
        self.isGroup = isGroup
        self.hasMeaningfulContent = hasMeaningfulContent
    }
}

public enum CaptureSummaryInputBuilder {
    public static func build(
        appLabel: String,
        sourceTitle: String?,
        url: String?,
        contentKind: CaptureContentKind,
        capturedAt: EpochMs,
        trigger: CaptureTrigger,
        structured: CapturedContent,
        delta: CaptureDelta,
        typedText: String?,
        timeZone: TimeZone = .current
    ) -> CaptureSummaryPromptInput {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        let iso = formatter.string(
            from: Date(timeIntervalSince1970: Double(capturedAt) / 1_000)
        )

        if case .conversation(let conversation) = structured {
            let messages = String(
                delta.addedMessages
                    .map(ContentRenderer.renderMessage)
                    .joined(separator: "\n")
                    .prefix(1_500)
            )
            return CaptureSummaryPromptInput(
                variant: .conversation,
                appLabel: appLabel,
                sourceTitle: sourceTitle,
                url: url,
                kind: contentKind,
                capturedAtISO8601: iso,
                trigger: trigger,
                onScreenMain: "",
                renderedDelta: messages,
                typedText: "",
                channel: conversation.channel,
                isGroup: conversation.isGroup,
                hasMeaningfulContent: !messages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }

        let main = ContentRenderer.render(structured, style: .mainOnly(maxChars: 3_000))
        let renderedDelta = CaptureDeltaRenderer.render(delta, maxChars: 1_500)
        let typed = String((typedText ?? "").prefix(500))
        return CaptureSummaryPromptInput(
            variant: .action,
            appLabel: appLabel,
            sourceTitle: sourceTitle,
            url: url,
            kind: contentKind,
            capturedAtISO8601: iso,
            trigger: trigger,
            onScreenMain: main,
            renderedDelta: renderedDelta,
            typedText: typed,
            channel: nil,
            isGroup: nil,
            hasMeaningfulContent: !main.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !renderedDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
}

public enum SessionSummaryInputBuilder {
    public static func timelineText(_ timeline: ActivityTimeline) -> String {
        TimelineBuilder.render(timeline, budgetChars: 6_000)
    }
}
