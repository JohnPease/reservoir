import SwiftUI
import SwiftData

@main
struct ReservoirApp: App {
    let modelContainer: ModelContainer = ReservoirApp.makeModelContainer()

    /// A corrupted on-disk store must not permanently lock the user out of a
    /// single-device, no-backend app. If the default store fails to load,
    /// try once more against a fresh store file before falling back to an
    /// in-memory container (data loss, but the app stays usable).
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)

        if let container = try? ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self) {
            return container
        }

        if let defaultStoreURL = ModelConfiguration().url as URL?, FileManager.default.fileExists(atPath: defaultStoreURL.path) {
            try? FileManager.default.removeItem(at: defaultStoreURL)
        }
        if let container = try? ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self) {
            return container
        }

        let fallbackConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
        guard let inMemoryContainer = try? ModelContainer(for: schema, configurations: fallbackConfiguration) else {
            fatalError("Failed to create even an in-memory ModelContainer — SwiftData itself is broken.")
        }
        return inMemoryContainer
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
    }
}
