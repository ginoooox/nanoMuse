// A new chat requested in All chats is opened by the shell after the sheet
// finishes dismissing. Keep the same draft id and options across that boundary.

import Foundation

struct NanoMuseDraftRequest: Equatable {
    let id: String
    var groupId: String? = nil
    var folderId: String? = nil
}

struct NanoMuseClassicNavigation {
    var restoreLaunchSession = true
    var presentDraft: ((NanoMuseDraftRequest) -> Void)? = nil
}

struct NanoMuseDraftHandoff {
    private var pending: NanoMuseDraftRequest?
    private var active: NanoMuseDraftRequest?

    mutating func request(_ draft: NanoMuseDraftRequest) {
        pending = draft
    }

    /// A normal swipe dismissal has no request and must not open a chat.
    mutating func finishDismissal() -> NanoMuseDraftRequest? {
        guard let draft = pending else { return nil }
        pending = nil
        active = draft
        return draft
    }

    func groupId(for draftId: String) -> String? {
        active?.id == draftId ? active?.groupId : nil
    }

    /// File only this draft's first promotion, never a different chat's event.
    mutating func takeFolder(for draftId: String?) -> String? {
        guard let draftId, active?.id == draftId else { return nil }
        let folder = active?.folderId
        active?.folderId = nil
        return folder
    }
}
