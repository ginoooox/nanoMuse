// Compile together with the shipping NanoMuseDraftHandoff.swift, without the
// app or the MinisTests target. This exercises the production state directly.

import Foundation

@main
enum DraftHandoffTests {
    static func main() {
        var handoff = NanoMuseDraftHandoff()
        precondition(handoff.finishDismissal() == nil, "Swiping away All chats must not create a chat")

        let first = NanoMuseDraftRequest(id: "__new__draft-a", groupId: "group-a", folderId: "folder-a")
        handoff.request(first)
        precondition(handoff.groupId(for: first.id) == nil, "Do not activate the draft before dismissal")
        precondition(handoff.takeFolder(for: first.id) == nil, "Do not promote a pending draft")
        precondition(handoff.finishDismissal() == first, "Preserve the exact draft id and options")
        precondition(handoff.finishDismissal() == nil, "Repeated dismissal must not open a second draft")
        precondition(handoff.groupId(for: first.id) == "group-a")
        precondition(handoff.groupId(for: "existing-chat") == nil, "Never apply draft options to an existing chat")

        precondition(handoff.takeFolder(for: nil) == nil)
        precondition(handoff.takeFolder(for: "__new__unrelated") == nil)
        precondition(handoff.takeFolder(for: first.id) == "folder-a", "Unrelated promotions must not consume the folder")
        precondition(handoff.takeFolder(for: first.id) == nil, "File the promoted draft only once")
        precondition(handoff.groupId(for: first.id) == "group-a", "Filing must preserve the model group")

        let second = NanoMuseDraftRequest(id: "__new__draft-b")
        let third = NanoMuseDraftRequest(id: "__new__draft-c")
        handoff.request(second)
        handoff.request(third)
        precondition(handoff.finishDismissal() == third, "Rapid requests must open only the latest draft")
        precondition(handoff.groupId(for: first.id) == nil, "A new draft must not inherit the previous options")
        precondition(handoff.takeFolder(for: third.id) == nil)

        handoff.request(first)
        handoff = NanoMuseDraftHandoff()
        precondition(handoff.finishDismissal() == nil, "An account switch must discard pending navigation")
        precondition(handoff.groupId(for: first.id) == nil)
        precondition(handoff.takeFolder(for: first.id) == nil)

        let standalone = NanoMuseClassicNavigation()
        precondition(standalone.restoreLaunchSession && standalone.presentDraft == nil)
        var received: NanoMuseDraftRequest?
        let embedded = NanoMuseClassicNavigation(restoreLaunchSession: false, presentDraft: { received = $0 })
        precondition(!embedded.restoreLaunchSession)
        embedded.presentDraft?(first)
        precondition(received == first, "The embedded page must pass every draft option to its owner")
        print("Draft handoff regression checks passed")
    }
}
