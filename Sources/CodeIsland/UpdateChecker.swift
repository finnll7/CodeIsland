import AppKit
import Combine
import os.log

/// Simplified update state — kept as a stub since auto-update has been removed.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case failed(String)
}

@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()
    private static let log = Logger(subsystem: "com.codeisland", category: "UpdateChecker")

    @Published private(set) var state: UpdateState = .idle

    var isHomebrewInstall: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/Caskroom/") || path.contains("/homebrew/")
    }

    func start() {
        // Auto-update has been removed to reduce runtime overhead.
    }

    func checkForUpdates() {
        // Auto-update has been removed.
    }

    func performUpdate() {
        // Auto-update has been removed.
    }
}
