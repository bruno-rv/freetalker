import Foundation

@MainActor
final class RecoveryLaunchGate {
    private var active: (id: UUID, task: Task<Void, Never>)?

    func run(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        if let active { await active.task.value; return }
        let id = UUID()
        let task = Task { await operation() }
        active = (id, task)
        await task.value
        if active?.id == id { active = nil }
    }
}
