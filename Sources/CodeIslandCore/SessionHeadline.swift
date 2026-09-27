import Foundation

/// What a session card leads with.
///
/// The session title is the task name the user recognises — the collapsed
/// bar already leads with it — so a titled card leads with the title and
/// follows with the project folder as a smaller link. With "Show project
/// name" off, no folder name may appear on the card at all (screen sharing,
/// demos, client work); an untitled session falls back to the folder (or the
/// agent's name when the folder is hidden) rather than showing nothing.
public struct SessionHeadline: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The project folder (clickable: reveals the folder in Finder).
        case project
        /// The session's own title (Claude custom/AI title, Codex thread name…).
        case sessionTitle
        /// No title yet — the agent's display name ("Claude", "Codex"…).
        case agent
    }

    public let text: String
    public let kind: Kind
    /// Project folder rendered after a leading session title; nil when the
    /// folder already *is* the lead (or is hidden).
    public let trailingProjectName: String?

    public init(text: String, kind: Kind, trailingProjectName: String? = nil) {
        self.text = text
        self.kind = kind
        self.trailingProjectName = trailingProjectName
    }

    /// Short context line for places outside the card (collapsed bar, question
    /// card header) that show the project folder today. Returns nil when there
    /// is nothing to show, so callers can drop the element entirely.
    public static func contextLabel(
        projectName: String?,
        sessionLabel: String?,
        showProjectName: Bool
    ) -> String? {
        showProjectName ? projectName : sessionLabel
    }
}

extension SessionSnapshot {
    public func headline(showProjectName: Bool) -> SessionHeadline {
        if let sessionLabel {
            return SessionHeadline(
                text: sessionLabel,
                kind: .sessionTitle,
                trailingProjectName: showProjectName ? projectDisplayName : nil
            )
        }
        if showProjectName {
            return SessionHeadline(text: projectDisplayName, kind: .project)
        }
        return SessionHeadline(text: sourceLabel, kind: .agent)
    }
}
