import Foundation
import Observation

@MainActor
@Observable
public final class DataControlsViewModel {
    public private(set) var status: String
    public private(set) var isWorking = false

    private let onExport: @MainActor @Sendable () async throws -> String
    private let onApplyRetention: @MainActor @Sendable () async throws -> String
    private let onDeleteAll: @MainActor @Sendable () async throws -> String
    private let onRestore: @MainActor @Sendable () async throws -> String
    private let onExportDiagnostics: @MainActor @Sendable () async throws -> String
    private let onRevealLogs: @MainActor @Sendable () -> String

    public init(
        onExport: @escaping @MainActor @Sendable () async throws -> String,
        onApplyRetention: @escaping @MainActor @Sendable () async throws -> String,
        onDeleteAll: @escaping @MainActor @Sendable () async throws -> String,
        onRestore: @escaping @MainActor @Sendable () async throws -> String = {
            "Database restore is unavailable"
        },
        onExportDiagnostics: @escaping @MainActor @Sendable () async throws -> String = {
            "Diagnostics export is unavailable"
        },
        onRevealLogs: @escaping @MainActor @Sendable () -> String = {
            "Logs are unavailable"
        },
        initialStatus: String = ""
    ) {
        status = initialStatus
        self.onExport = onExport
        self.onApplyRetention = onApplyRetention
        self.onDeleteAll = onDeleteAll
        self.onRestore = onRestore
        self.onExportDiagnostics = onExportDiagnostics
        self.onRevealLogs = onRevealLogs
    }

    public func export() async { await perform(onExport) }
    public func applyRetention() async { await perform(onApplyRetention) }
    public func deleteAll() async { await perform(onDeleteAll) }
    public func restore() async { await perform(onRestore) }
    public func exportDiagnostics() async { await perform(onExportDiagnostics) }
    public func revealLogs() { status = onRevealLogs() }

    private func perform(_ operation: @MainActor @Sendable () async throws -> String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { status = try await operation() }
        catch { status = "Data operation failed: \(error.localizedDescription)" }
    }
}
