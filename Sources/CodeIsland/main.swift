// main.swift — plain AppKit entry point.
//
// The app previously used the SwiftUI `@main App` lifecycle with a
// `Settings { EmptyView() }` placeholder scene. macOS 15+ auto-opens that
// scene's window at launch for accessory apps — a blank "CodeIsland Settings"
// shell with no purpose (the real settings UI is SettingsWindowController,
// opened from the gear icon) — and kept reopening it on activation, which
// `orderOut` could not durably suppress. This app manages all of its windows
// manually anyway (notch panel, settings, status item), so the SwiftUI scene
// machinery served no purpose and is gone entirely.

import AppKit

let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
