import Testing
@testable import Muster

@Suite @MainActor struct SkillReadViewTests {
    @Test func skillMetadataIsHiddenOnlyWhenRequested() {
        let text = "---\nname: test\ndescription: Test\n---\n\n# Title\n\nBody **bold**."
        let blocks = SkillReadView.blocks(text, stripMetadata: true)
        #expect(blocks == [.init(kind: .heading(1), text: "Title"), .init(kind: .paragraph, text: "Body **bold**.")])
        #expect(SkillReadView.blocks(text).first?.text.contains("name: test") == true)
    }

    @Test func fencedCodePreservesWhitespaceAndDoesNotTurnIntoHeadings() {
        let text = "## Guide\n\n```sh\n# comment\n  echo test\n\n```\n\nTail"
        let blocks = SkillReadView.blocks(text)
        #expect(blocks.count == 3)
        #expect(blocks[1] == .init(kind: .code, text: "# comment\n  echo test\n"))
    }

    @Test func unfinishedFencesAndFrontmatterKeepTheText() {
        #expect(SkillReadView.blocks("---\nname: unfinished", stripMetadata: true).first?.text == "---\nname: unfinished")
        #expect(SkillReadView.blocks("~~~\n# still code") == [.init(kind: .code, text: "# still code")])
        #expect(SkillReadView.blocks("####### literal") == [.init(kind: .paragraph, text: "####### literal")])
    }
}
