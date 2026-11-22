import Foundation
import Testing
@testable import Ghostty

/// The native pick list must filter as pcode does: this is the table in
/// pcode's `tests/test_pick_ui.py` (`FUZZY_CASES`), case for case.
@Suite
struct PCodePickMatchTests {
    static let fuzzyCases: [(String, String, Bool)] = [
        ("edit_ui", "src/pcode/edit_ui.py", true),
        ("ed_ui", "src/pcode/edit_ui.py", true),
        ("pc/edui", "src/pcode/edit_ui.py", true),
        ("edui", "src/pcode/edit_ui.py", true),
        ("dtui", "src/pcode/edit_ui.py", false),
        ("sel_row", "+self.selected_row = 1", true),
        ("_", "anything", false),
        ("", "anything", true),
        ("anthopus", "anthropic claude-opus-5", true),
        ("anthopus", "anthropic:claude-sonnet-5", false),
        ("claopus", "anthropic:claude-opus-5", true),
        ("codluna", "openai-codex:gpt-5.6-luna", true),
        ("gpt-5.6", "openai-codex:gpt-5.6-luna", true),
        ("gpt56", "openai-codex:gpt-5.6-luna", true),
        ("g5l", "openai-codex:gpt-5.6-luna", true),
        ("lunagpt", "openai-codex:gpt-5.6-luna", false),
        ("aab", "aa ab", true),
        ("abc", "a-b-c", true),
        ("abd", "ab-c", false),
        ("café", "le café", true),
        ("cafe", "le café", false),
        ("x", "", false),
    ]

    @Test(arguments: fuzzyCases)
    func fuzzyMatchesLikePcode(term: String, text: String, expected: Bool) {
        #expect(PCodePickMatch.fuzzy(term, text) == expected)
    }

    static let treeCases: [([Int], [String])] = [
        ([0, 1, 2, 1, 0, 1, 1, 2, 0], ["", "├─ ", "│  └─ ", "└─ ", "", "├─ ", "└─ ", "   └─ ", ""]),
        ([2, 3, 0], ["", "└─ ", ""]),
        ([0, 1, 2, 3, 1], ["", "├─ ", "│  └─ ", "│     └─ ", "└─ "]),
    ]

    @Test(arguments: treeCases)
    func treeGuidesLikeNestForks(depths: [Int], guides: [String]) {
        #expect(PCodePickMatch.treeGuides(depths) == guides)
    }

    @Test func customRowsNeedTheWholeQuery() throws {
        let pattern = try #require(PCodePickMatch.anchored("(?:openai|openai-codex):[A-Za-z0-9_.:/-]+"))
        #expect(PCodePickMatch.fullMatch(pattern, "openai-codex:x"))
        #expect(PCodePickMatch.fullMatch(pattern, "openai:x"))
        #expect(!PCodePickMatch.fullMatch(pattern, "openai:bad id"))
        #expect(!PCodePickMatch.fullMatch(pattern, "xopenai:a"))
    }
}
