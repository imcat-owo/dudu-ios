import Foundation

// Session/agent-loop notification names.
// Extracted from OpenMinis MinisApp.swift (GPL-3.0) — pure Foundation, no UI.
// These are posted/observed by engine code (ChatStore, AIChatViewModel); the
// Dudu UI layer observes them to refresh.

extension Notification.Name {
    static let newChatRequested = Notification.Name("newChatRequested")
    /// Posted when a new session is persisted to the database. `object` is the session ID (`String`).
    static let sessionDidCreate = Notification.Name("sessionDidCreate")
    /// Posted when a session's title or messages are updated.
    static let sessionDidUpdate = Notification.Name("sessionDidUpdate")
    /// Posted when an agent loop ends on a VM that is not the currently-displayed one.
    /// `object` is the session ID (`String`). Allows the active VM to reload from DB.
    static let sessionAgentLoopDidEnd = Notification.Name("sessionAgentLoopDidEnd")
    /// Posted after a memory file (GLOBAL.md or daily log) is written
    /// locally. Observers can use this to refresh their in-memory snapshot
    /// of memory files.
    static let memoryFilesDidChange = Notification.Name("com.openminis.clone.memoryFilesDidChange")
    /// Posted by any path that's about to take over the screen (incoming
    /// share, WebApp deep-link launch). Every fullScreenCover host listens
    /// and dismisses its covers so the new content actually surfaces instead
    /// of getting stuck behind a leftover WebView / camera / gallery sheet.
    static let dismissAllImmersivePresentations = Notification.Name("dismissAllImmersivePresentations")
    /// Posted when user attachments are mounted (message-list height cache
    /// invalidation signal in the original UI; kept for engine parity).
    static let minisUserAttachmentsMounted = Notification.Name("minisUserAttachmentsMounted")
}
