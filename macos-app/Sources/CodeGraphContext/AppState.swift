import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    let pythonManager = PythonManager()
    let indexingManager = IndexingManager()

    var serverPort: Int { pythonManager.mcpPort }
    var vizPort: Int { pythonManager.vizPort }

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Forward child ObservableObject changes so SwiftUI views update.
        // Throttle to max 1 update per second to avoid runaway re-renders.
        pythonManager.objectWillChange
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        indexingManager.objectWillChange
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Keep indexing manager's port in sync
        indexingManager.mcpPort = pythonManager.mcpPort

        // Auto-start servers on launch
        start()
    }

    func start() {
        pythonManager.startAll()

        // Single initial data fetch after services have started
        Task {
            try? await Task.sleep(for: .seconds(8))
            await indexingManager.refreshAll()
        }
    }

    func stop() {
        Task { await indexingManager.unwatchAll() }
        pythonManager.stopAll()
    }

    /// Called when user opens the menu — refresh data on demand
    func refreshOnMenuOpen() {
        Task {
            await indexingManager.refreshAll()
            if indexingManager.isIndexing {
                await indexingManager.pollJobProgress()
            }
        }
    }
}

struct IndexedRepository: Identifiable {
    let id = UUID()
    let name: String
    let path: String
}
