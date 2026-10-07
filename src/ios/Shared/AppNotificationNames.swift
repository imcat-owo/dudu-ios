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
}
