import SwiftUI

@main struct MyApp: App {
    @StateObject private var updates = UpdateChecker()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("UnTilt") {
            ContentView()
                .task {
                    // Also covers an app left running for more than a week.
                    while !Task.isCancelled {
                        await updates.checkIfDue()
                        do { try await Task.sleep(for: .seconds(60 * 60)) }
                        catch { break }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await updates.checkIfDue() }
                    }
                }
        }
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updates.isChecking ? "Checking for Updates…" : "Check for Updates…") {
                    Task { await updates.check(manually: true) }
                }
                .disabled(updates.isChecking)
            }
        }
    }
}
