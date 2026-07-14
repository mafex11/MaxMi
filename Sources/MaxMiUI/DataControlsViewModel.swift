import Foundation
import Observation

@MainActor
@Observable
public final class DataControlsViewModel {
    public private(set) var status = ""
    public private(set) var isWorking = false

    private let onExport: @MainActor @Sendable () async throws -> String
    private let onApplyRetention: @MainActor @Sendable () async throws -> String
    private let onDeleteAll: @MainActor @Sendable () async throws -> String

    public init(
        onExport: @escaping @MainActor @Sendable () async throws -> String,
        onApplyRetention: @escaping @MainActor @Sendable () async throws -> String,
        onDeleteAll: @escaping @MainActor @Sendable () async throws -> String
    ) {
        self.onExport = onExport
        self.onApplyRetention = onApplyRetention
        self.onDeleteAll = onDeleteAll
    }

    public func export() async { await perform(onExport) }
    public func applyRetention() async { await perform(onApplyRetention) }
    public func deleteAll() async { await perform(onDeleteAll) }

    private func perform(_ operation: @MainActor @Sendable () async throws -> String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { status = try await operation() }
        catch { status = "Data operation failed: \(error.localizedDescription)" }
    }
}

