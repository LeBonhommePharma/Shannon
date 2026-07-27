import XCTest
@testable import PillCore
import ShannonCore

/// ENH-030: pure Mac voice callout policy matrix (fail-closed; no invented content).
final class VoiceCalloutPolicyTests: XCTestCase {

    // MARK: - shouldAnnounce matrix

    func testPrefOffNeverAnnounces() {
        for kind in VoiceCalloutKind.allCases {
            XCTAssertFalse(
                VoiceCalloutPolicy.shouldAnnounce(
                    kind: kind,
                    voiceCalloutsEnabled: false
                ),
                "\(kind) must stay silent when pref off"
            )
        }
    }

    func testPrefOnAllowsNeedsYouAndTaskComplete() {
        XCTAssertTrue(
            VoiceCalloutPolicy.shouldAnnounce(
                kind: .needsYou,
                voiceCalloutsEnabled: true
            )
        )
        XCTAssertTrue(
            VoiceCalloutPolicy.shouldAnnounce(
                kind: .taskComplete,
                voiceCalloutsEnabled: true
            )
        )
    }

    func testMutedNeverAnnouncesEvenWhenPrefOn() {
        for kind in VoiceCalloutKind.allCases {
            XCTAssertFalse(
                VoiceCalloutPolicy.shouldAnnounce(
                    kind: kind,
                    voiceCalloutsEnabled: true,
                    muted: true
                ),
                "\(kind) must stay silent when muted"
            )
        }
    }

    func testFocusActiveNeverAnnouncesEvenWhenPrefOn() {
        for kind in VoiceCalloutKind.allCases {
            XCTAssertFalse(
                VoiceCalloutPolicy.shouldAnnounce(
                    kind: kind,
                    voiceCalloutsEnabled: true,
                    focusActive: true
                ),
                "\(kind) must stay silent when Focus is active"
            )
        }
    }

    func testMutedAndFocusBothFailClosed() {
        XCTAssertFalse(
            VoiceCalloutPolicy.shouldAnnounce(
                kind: .needsYou,
                voiceCalloutsEnabled: true,
                muted: true,
                focusActive: true
            )
        )
    }

    // MARK: - spokenText (real tokens only)

    func testNeedsYouSpokenUsesSharedTokenWithAgent() {
        let text = VoiceCalloutPolicy.spokenText(kind: .needsYou, agentName: "claude_code")
        XCTAssertEqual(text, "claude_code needs you")
        XCTAssertEqual(
            text,
            AgentAttentionCopy.needsYouNotifyTitle(agentID: "claude_code")
        )
        XCTAssertTrue(text?.contains(AgentAttentionCopy.needsYou) == true)
    }

    func testNeedsYouSpokenTrimsWhitespace() {
        let text = VoiceCalloutPolicy.spokenText(kind: .needsYou, agentName: "  science  ")
        XCTAssertEqual(text, "science needs you")
    }

    func testNeedsYouEmptyAgentUsesApprovalNeededFallback() {
        // Same family as ShannonNotifier / GlobalNotify — not invented agent state.
        let text = VoiceCalloutPolicy.spokenText(kind: .needsYou, agentName: "  ")
        XCTAssertEqual(text, "Approval needed")
        XCTAssertEqual(
            text,
            AgentAttentionCopy.needsYouNotifyTitle(agentID: nil)
        )
    }

    func testTaskCompleteSpokenUsesDoneToken() {
        let text = VoiceCalloutPolicy.spokenText(kind: .taskComplete, agentName: "science")
        XCTAssertEqual(text, "science \(AgentAttentionCopy.done)")
        XCTAssertEqual(text, "science done")
    }

    func testTaskCompleteEmptyAgentIsNil() {
        // Never invent who finished.
        XCTAssertNil(VoiceCalloutPolicy.spokenText(kind: .taskComplete, agentName: ""))
        XCTAssertNil(VoiceCalloutPolicy.spokenText(kind: .taskComplete, agentName: "   "))
    }

    // MARK: - decide combines gates + content

    func testDecidePrefOffIsNil() {
        XCTAssertNil(
            VoiceCalloutPolicy.decide(
                kind: .needsYou,
                agentName: "a",
                voiceCalloutsEnabled: false
            )
        )
    }

    func testDecidePrefOnReturnsSpoken() {
        XCTAssertEqual(
            VoiceCalloutPolicy.decide(
                kind: .needsYou,
                agentName: "codex",
                voiceCalloutsEnabled: true
            ),
            "codex needs you"
        )
        XCTAssertEqual(
            VoiceCalloutPolicy.decide(
                kind: .taskComplete,
                agentName: "codex",
                voiceCalloutsEnabled: true
            ),
            "codex done"
        )
    }

    func testDecideMutedIsNil() {
        XCTAssertNil(
            VoiceCalloutPolicy.decide(
                kind: .taskComplete,
                agentName: "a",
                voiceCalloutsEnabled: true,
                muted: true
            )
        )
    }

    func testDecideFocusIsNil() {
        XCTAssertNil(
            VoiceCalloutPolicy.decide(
                kind: .needsYou,
                agentName: "a",
                voiceCalloutsEnabled: true,
                focusActive: true
            )
        )
    }

    func testDecideTaskCompleteEmptyAgentNilEvenWhenEnabled() {
        XCTAssertNil(
            VoiceCalloutPolicy.decide(
                kind: .taskComplete,
                agentName: "",
                voiceCalloutsEnabled: true
            )
        )
    }

    // MARK: - completion event type (explicit only)

    func testIsTaskCompleteEventTypeExplicitTokens() {
        XCTAssertTrue(VoiceCalloutPolicy.isTaskCompleteEventType("task_complete"))
        XCTAssertTrue(VoiceCalloutPolicy.isTaskCompleteEventType("task_completed"))
        XCTAssertTrue(VoiceCalloutPolicy.isTaskCompleteEventType("COMPLETED"))
        XCTAssertTrue(VoiceCalloutPolicy.isTaskCompleteEventType(" done "))
        XCTAssertTrue(VoiceCalloutPolicy.isTaskCompleteEventType("finish"))
        XCTAssertFalse(VoiceCalloutPolicy.isTaskCompleteEventType("tool_call"))
        XCTAssertFalse(VoiceCalloutPolicy.isTaskCompleteEventType("status"))
        XCTAssertFalse(VoiceCalloutPolicy.isTaskCompleteEventType("approval_needed"))
        XCTAssertFalse(VoiceCalloutPolicy.isTaskCompleteEventType(""))
    }

    func testNewTaskCompleteCalloutsSkipsSeenAndNonComplete() {
        let activity: [(id: Int64, agentId: String, type: String)] = [
            (1, "a", "tool_call"),
            (2, "science", "task_complete"),
            (3, "b", "status"),
            (4, "codex", "done"),
            (2, "science", "task_complete"), // duplicate id
        ]
        let first = VoiceCalloutPolicy.newTaskCompleteCallouts(
            activity: activity,
            previouslySeenIds: []
        )
        XCTAssertEqual(first.map(\.id), [2, 4])
        XCTAssertEqual(first.map(\.agentId), ["science", "codex"])

        let again = VoiceCalloutPolicy.newTaskCompleteCallouts(
            activity: activity,
            previouslySeenIds: Set(first.map(\.id))
        )
        XCTAssertTrue(again.isEmpty, "baseline must suppress re-announce")
    }

    func testNewTaskCompleteSkipsEmptyAgent() {
        let rows: [(id: Int64, agentId: String, type: String)] = [
            (9, "  ", "task_complete"),
            (10, "real", "task_complete"),
        ]
        let out = VoiceCalloutPolicy.newTaskCompleteCallouts(
            activity: rows,
            previouslySeenIds: []
        )
        XCTAssertEqual(out.map(\.agentId), ["real"])
    }

    // MARK: - MacVoiceCallout speaker gate

    @MainActor
    func testMacVoiceCalloutRespectsPrefOff() {
        let synth = RecordingSynthesizer()
        let voice = MacVoiceCallout(synthesizer: synth)
        voice.voiceCalloutsEnabled = { false }
        voice.announce(kind: .needsYou, agentName: "a")
        XCTAssertTrue(synth.spoken.isEmpty)
        XCTAssertNil(voice.lastSpoken)
    }

    @MainActor
    func testMacVoiceCalloutSpeaksWhenEnabled() {
        let synth = RecordingSynthesizer()
        let voice = MacVoiceCallout(synthesizer: synth)
        voice.voiceCalloutsEnabled = { true }
        voice.announce(kind: .needsYou, agentName: "claude_code")
        XCTAssertEqual(synth.spoken, ["claude_code needs you"])
        XCTAssertEqual(voice.lastSpoken, "claude_code needs you")

        voice.announce(kind: .taskComplete, agentName: "science")
        XCTAssertEqual(synth.spoken.last, "science done")
    }

    @MainActor
    func testMacVoiceCalloutMutedAndFocus() {
        let synth = RecordingSynthesizer()
        let voice = MacVoiceCallout(synthesizer: synth)
        voice.voiceCalloutsEnabled = { true }

        voice.isMuted = { true }
        voice.announce(kind: .needsYou, agentName: "a")
        XCTAssertTrue(synth.spoken.isEmpty)

        voice.isMuted = { false }
        voice.isFocusActive = { true }
        voice.announce(kind: .taskComplete, agentName: "b")
        XCTAssertTrue(synth.spoken.isEmpty)
    }

    @MainActor
    func testSpeakIfPresentNoopsOnEmpty() {
        let synth = RecordingSynthesizer()
        let voice = MacVoiceCallout(synthesizer: synth)
        voice.speakIfPresent(nil)
        voice.speakIfPresent("")
        XCTAssertTrue(synth.spoken.isEmpty)
        voice.speakIfPresent("codex done")
        XCTAssertEqual(synth.spoken, ["codex done"])
    }
}
