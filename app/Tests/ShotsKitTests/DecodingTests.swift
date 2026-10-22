import Foundation
import Testing
@testable import ShotsKit

struct DecodingTests {
    @Test func decodesRecatOutput() throws {
        let json = #"""
        {"shot":{"id":2,"path":"/Users/me/Screenshots/ui-reference/2026-10-21_1816_panel.png","original_name":"Screenshot 2026-10-21 at 6.16.04 PM.png","sha256":"abc","captured_at":"2026-10-22T01:16:04.794Z","processed_at":"2026-10-22T01:16:11Z","app_bundle_id":"com.google.Chrome","app_name":"Google Chrome","window_title":"Queue","url":"https://example.com/q","url_title":"Queue","capture_type":"selection","width":1440,"height":900,"ocr_text":"Queued","category":"ui-reference","suggested_category":null,"tags_json":"[\"dashboard\",\"workers\"]","tags_text":"dashboard workers","title":"Queued task status panel","confidence":0.86,"backend":"claude-code","review":0,"attempts_json":null},
         "decision":{"final":{"category":"ui-reference","tags":["dashboard","workers"],"title":"Queued task status panel","confidence":0.86},"backend":"claude-code","review":false,"suggestedCategory":null,"attempts":[{"backend":"claude-code","ms":5012,"outcome":{"ok":true}}]}}
        """#
        let result = try JSONDecoder().decode(RecatResult.self, from: Data(json.utf8))
        let shot = result.shot
        #expect(shot.id == 2)
        #expect(shot.fileName == "2026-10-21_1816_panel.png")
        #expect(shot.tags == ["dashboard", "workers"])
        #expect(shot.pageURL == URL(string: "https://example.com/q"))
        #expect(shot.pixelSize == "1440 × 900")
        #expect(shot.classifierBackend == .claudeCode)
        #expect(!shot.needsReview)
        #expect(abs(shot.capturedAt.timeIntervalSince1970 - 1_792_631_764.794) < 0.001)
        #expect(result.decision.final.category == "ui-reference")
        #expect(result.decision.backend == "claude-code")
    }

    @Test func badTagsJSONMeansNoTags() {
        #expect(Shot.decodeTags("not json") == [])
        #expect(Shot.decodeTags(nil) == [])
    }

    @Test func decodesConfigOutput() throws {
        let json = #"""
        {"path":"/Users/me/.config/shots/config.json","dbPath":"/Users/me/.local/share/shots/shots.db",
         "config":{"inbox":"/Users/me/Screenshots/_inbox","outputRoot":"/Users/me/Screenshots","categories":["code","misc"],
                   "categoryHints":{"code":"source code"},"backends":["apple"],"timeoutMs":30000}}
        """#
        let config = try JSONDecoder().decode(ShotsConfig.self, from: Data(json.utf8))
        #expect(config.dbPath == "/Users/me/.local/share/shots/shots.db")
        #expect(config.categories == ["code", "misc"])
        #expect(config.categoryHints["code"] == "source code")
        #expect(config.inboxURL.path == "/Users/me/Screenshots/_inbox")
    }
}
