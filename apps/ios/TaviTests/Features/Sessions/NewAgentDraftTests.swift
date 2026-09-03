import Foundation
@testable import Tavi
import Testing

// What the New Agent sheet holds the moment it opens (#75, #100, #105):
// which computer, where the agent starts, and whether that place is still
// a question. Everything else the sheet fills in from the host.
@MainActor
struct NewAgentDraftTests {
    private func computers(_ ids: String...) -> [HostFleet.Entry] {
        ids.map { id in
            let directory = AgentDirectory(transport: StubHost().transport, makeSocket: FakeSockets().make)
            return HostFleet.Entry(host: Fixtures.pairedHost(id: id), directory: directory)
        }
    }

    // MARK: - Which computer

    // One paired computer is not a question worth asking.
    @Test func theOnlyPairedComputerIsChosenWithoutAsking() {
        let draft = NewAgentDraft(computers: computers("fp-1"), startingIn: nil, startMode: .folder)
        #expect(draft.chosenHostId == "fp-1")
        #expect(draft.phase == .loading)
    }

    @Test func twoPairedComputersAreAskedAboutFirst() {
        let draft = NewAgentDraft(computers: computers("fp-1", "fp-2"), startingIn: nil, startMode: .folder)
        #expect(draft.phase == .chooseComputer)
    }

    @Test func startingSomewhereKnownSkipsTheQuestionEvenWithTwoComputers() {
        let draft = NewAgentDraft(
            computers: computers("fp-1", "fp-2"),
            startingIn: (hostId: "fp-2", path: "/repo"),
            startMode: .folder
        )
        #expect(draft.chosenHostId == "fp-2")
    }

    // MARK: - Where the agent starts

    @Test func theFolderTheSheetStartsOnIsTheOneItWasOpenedFrom() {
        let fromNowhere = NewAgentDraft(computers: computers("fp-1"), startingIn: nil, startMode: .folder)
        let fromACard = NewAgentDraft(
            computers: computers("fp-1"),
            startingIn: (hostId: "fp-1", path: "/repo"),
            startMode: .folder
        )
        #expect(fromNowhere.selectedPath == nil)
        #expect(fromACard.selectedPath == "/repo")
    }

    // "Start an agent here" already knows the place, so it is one row
    // rather than a list with a checkmark buried in it.
    @Test func startAnAgentHereLocksThePlaceToOneRow() {
        let draft = NewAgentDraft(
            computers: computers("fp-1"),
            startingIn: (hostId: "fp-1", path: "/repo"),
            startMode: .folder
        )
        #expect(draft.whereLocked)
    }

    @Test func aSheetOpenedFromNowhereLeavesThePlaceOpen() {
        let draft = NewAgentDraft(computers: computers("fp-1"), startingIn: nil, startMode: .folder)
        #expect(draft.whereLocked == false)
    }

    // MARK: - The worktree the card offered

    @Test func newWorktreeFromACardOpensInWorktreeMode() {
        let draft = NewAgentDraft(
            computers: computers("fp-1"),
            startingIn: (hostId: "fp-1", path: "/repo"),
            startMode: .worktree
        )
        #expect(draft.whereMode == .worktree)
    }

    // The branch still has to be chosen, so the place stays open.
    @Test func newWorktreeFromACardLeavesThePlaceOpen() {
        let draft = NewAgentDraft(
            computers: computers("fp-1"),
            startingIn: (hostId: "fp-1", path: "/repo"),
            startMode: .worktree
        )
        #expect(draft.whereLocked == false)
    }

    // Worktree mode is only ever offered from a card that named a folder;
    // the plain "+" always starts on a folder.
    @Test func aSheetOpenedFromNowhereStartsOnAFolderWhateverWasAsked() {
        let draft = NewAgentDraft(computers: computers("fp-1"), startingIn: nil, startMode: .worktree)
        #expect(draft.whereMode == .folder)
    }
}
