import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The creative critic's last nits, taken after the merge.
extension CreativeScreenTests {

    /// Clicking the fine-tune already open again keeps what was typed: its details are fetched
    /// again and merged field by field, never refilled from the list's entry.
    @Test func reChoosingTheOpenFineTuneKeepsWhatWasTyped() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(MusicScreenModel.listFinetunes, .json(["finetunes": [Self.finetuneJSON("A", "Alpha", genre: "house")],
                                                          "has_more": false]))
        rig.always(MusicScreenModel.getFinetune, .json(Self.finetuneJSON("A", "Alpha", genre: "techno")))
        let music = rig.session.music
        await music.refreshFinetunes()
        await music.select(music.finetunes[0])
        #expect(music.editGenre == "techno")
        music.editName = "Typed"
        await music.select(music.finetunes[0])
        #expect(music.editName == "Typed", "re-choosing the open fine-tune dropped the typing")
        #expect(music.editGenre == "techno", "an untouched field keeps the details' value, not the list's")
        #expect(rig.requests(MusicScreenModel.getFinetune).count == 2, "its details are fetched again")
        #expect(music.updateArguments() == ["finetune_id": "A", "name": "Typed"])
    }

    /// Create requires a primary genre; an edit that empties it is refused with the same words
    /// before anything is sent. A fine-tune that never had a genre can still be renamed.
    @Test func anEditThatEmptiesTheGenreIsRefused() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(MusicScreenModel.listFinetunes, .json(["finetunes": [
            Self.finetuneJSON("A", "Alpha", genre: "house"), Self.finetuneJSON("B", "Beta"),
        ], "has_more": false]))
        rig.always(MusicScreenModel.getFinetune, .json(Self.finetuneJSON("A", "Alpha", genre: "house")))
        rig.always(MusicScreenModel.updateFinetune, .json(Self.finetuneJSON("A", "Alpha", genre: "house")))
        let music = rig.session.music
        await music.refreshFinetunes()
        await music.select(music.finetunes[0])
        for blank in ["", "   "] {
            music.editGenre = blank
            #expect(music.editProblems.contains("Name the primary genre."), "“\(blank)” was not refused")
            await music.saveFinetune()
            #expect(rig.requests(MusicScreenModel.updateFinetune).isEmpty, "an empty genre was sent")
        }
        music.editGenre = "techno"
        #expect(music.editProblems.isEmpty)

        rig.always(MusicScreenModel.getFinetune, .json(Self.finetuneJSON("B", "Beta")))
        await music.select(music.finetunes[1])
        music.editName = "Beta 2"
        #expect(music.editProblems.isEmpty, "no genre to begin with: a rename is not refused")
    }
}
