import Foundation

/// Answers "is this process a unit-test host or a UI-test launch?" so features with real
/// device side effects (widget reloads, notification delivery) can swap in inert doubles.
enum TestProcessGate {
    /// True for a unit-test host or any UI-test launch (the explicit disable key, or any
    /// other `UITEST_*` variable as a backstop for launches that bypass the shared helper).
    nonisolated static func isTestProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment[WidgetSnapshotPublisher.uiTestDisableKey] != nil
            || environment.keys.contains { $0.hasPrefix("UITEST_") }
    }
}
