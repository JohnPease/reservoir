import SwiftUI
import SwiftData

@main
struct ReservoirApp: App {
    let modelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV1.self)
        do {
            return try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
    }
}
