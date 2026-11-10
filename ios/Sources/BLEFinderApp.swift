import SwiftUI

@main
struct BLEFinderApp: App {
    @StateObject private var scanner = Scanner()
    @StateObject private var tracker = Tracker()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
                .environmentObject(tracker)
        }
    }
}
