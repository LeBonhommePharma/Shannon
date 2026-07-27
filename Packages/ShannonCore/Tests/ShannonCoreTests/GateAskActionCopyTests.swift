import XCTest
@testable import ShannonCore

/// UX-003 — Approve/Deny affordance parity (Mac gate ↔ phone confirmation).
final class GateAskActionCopyTests: XCTestCase {

    private func pending(
        question: String = "Run migrate?",
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) -> PendingConfirmation {
        PendingConfirmation(
            id: "ask-1",
            question: question,
            agentID: "science",
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    func testCanonicalVerbs() {
        XCTAssertEqual(GateAskActionCopy.approve, "Approve")
        XCTAssertEqual(GateAskActionCopy.deny, "Deny")
        XCTAssertEqual(GateAskActionCopy.needsApproval, "needs approval")
        // UX-034: past-tense audit outcomes (pad Gate Activity) share verb roots.
        XCTAssertEqual(GateAskActionCopy.outcomeApproved, "approved")
        XCTAssertEqual(GateAskActionCopy.outcomeDenied, "denied")
        XCTAssertEqual(GateAskActionCopy.outcomeLabel(approved: true), "approved")
        XCTAssertEqual(GateAskActionCopy.outcomeLabel(approved: false), "denied")
        // Verb roots (case-insensitive prefix family — not full substring of Deny/denied).
        XCTAssertTrue(GateAskActionCopy.outcomeApproved.hasPrefix("approv"))
        XCTAssertTrue(GateAskActionCopy.outcomeDenied.hasPrefix("den"))
        XCTAssertNotEqual(GateAskActionCopy.outcomeApproved, GateAskActionCopy.approve)
        XCTAssertNotEqual(GateAskActionCopy.outcomeDenied, GateAskActionCopy.deny)
        // UX-023: delivery chrome tokens (watch face + gate status).
        XCTAssertEqual(GateAskActionCopy.sending, "Sending…")
        XCTAssertEqual(GateAskActionCopy.sent, "Sent ✓")
        XCTAssertFalse(GateAskActionCopy.queuedForPhone.isEmpty)
        XCTAssertTrue(GateAskActionCopy.queuedForPhone.localizedCaseInsensitiveContains("iphone"))
        // UX-033: watch gate phone-away chip (distinct from post-answer queued).
        XCTAssertEqual(GateAskActionCopy.phoneAwayChip, "iPhone away")
        XCTAssertTrue(GateAskActionCopy.phoneAwayChip.localizedCaseInsensitiveContains("iphone"))
        XCTAssertNotEqual(
            GateAskActionCopy.phoneAwayChip,
            GateAskActionCopy.queuedForPhone,
            "chip is compact status; queued is post-answer delivery"
        )
        // UX-027: menu-bar roster tertiary hint shares approve verb root.
        XCTAssertEqual(GateAskActionCopy.rosterApproveHint, "Gate · approve")
        XCTAssertTrue(
            GateAskActionCopy.rosterApproveHint.localizedCaseInsensitiveContains("approve")
        )
        XCTAssertFalse(GateAskActionCopy.rosterApproveAccessibility.isEmpty)
        XCTAssertTrue(
            GateAskActionCopy.rosterApproveAccessibility
                .localizedCaseInsensitiveContains("approve")
        )
        // UX-051: rectangular complication gate-glance header (no H/metrics).
        XCTAssertEqual(GateAskActionCopy.gateGlanceTitle, "Shannon asks")
        XCTAssertFalse(GateAskActionCopy.gateGlanceTitle.isEmpty)
        XCTAssertEqual(GateAskActionCopy.gateGlanceHeader(pendingCount: 0), "Shannon asks")
        XCTAssertEqual(GateAskActionCopy.gateGlanceHeader(pendingCount: 1), "Shannon asks")
        XCTAssertEqual(
            GateAskActionCopy.gateGlanceHeader(pendingCount: 2),
            "Shannon asks (2)"
        )
        XCTAssertEqual(
            GateAskActionCopy.gateGlanceHeader(pendingCount: 5),
            "Shannon asks (5)"
        )
        // Count only when >1; never invent H or docking metrics.
        XCTAssertFalse(GateAskActionCopy.gateGlanceHeader(pendingCount: 3).contains("H "))
        XCTAssertFalse(GateAskActionCopy.gateGlanceHeader(pendingCount: 3).contains("Å"))
        XCTAssertNotEqual(
            GateAskActionCopy.gateGlanceTitle,
            GateAskActionCopy.needsApproval,
            "glance header is density chrome; needsApproval is capsule badge"
        )
    }

    func testCompanionAnswerableWhenSyncOK() {
        let a = GateAskActionCopy.companionAffordance(
            pending: pending(),
            lastError: nil
        )
        XCTAssertTrue(a.canInteract)
        XCTAssertNil(a.statusMessage)
        XCTAssertEqual(a.approveLabel, "Approve")
        XCTAssertEqual(a.denyLabel, "Deny")
    }

    func testCompanionDisablesWhenHubOffline() {
        let a = GateAskActionCopy.companionAffordance(
            pending: pending(),
            lastError: "CKError network"
        )
        XCTAssertFalse(a.canInteract)
        XCTAssertEqual(a.statusMessage, GateAskActionCopy.companionSyncOffline)
        XCTAssertTrue(a.statusMessage?.contains("Hub offline") == true)
        // Must not look silently tappable while offline.
        XCTAssertNotEqual(a.statusMessage, nil)
    }

    func testCompanionDisablesWhenExpired() {
        let now = Date()
        let a = GateAskActionCopy.companionAffordance(
            pending: pending(expiresAt: now.addingTimeInterval(-1), createdAt: now.addingTimeInterval(-100)),
            lastError: nil,
            now: now
        )
        XCTAssertFalse(a.canInteract)
        XCTAssertEqual(a.statusMessage, GateAskActionCopy.promptUnanswerable)
    }

    func testCompanionDisablesWhenEmptyQuestion() {
        let a = GateAskActionCopy.companionAffordance(
            pending: pending(question: "   "),
            lastError: nil
        )
        XCTAssertFalse(a.canInteract)
        XCTAssertEqual(a.statusMessage, GateAskActionCopy.promptUnanswerable)
    }

    func testMacGateOfflineCopy() {
        let a = GateAskActionCopy.macGateAffordance(gateAvailable: false)
        XCTAssertFalse(a.canInteract)
        XCTAssertEqual(a.statusMessage, GateAskActionCopy.macGateOffline)
        XCTAssertEqual(
            a.statusMessage,
            "Hub offline — start the gate to approve from here"
        )
    }

    func testMacGateAvailable() {
        let a = GateAskActionCopy.macGateAffordance(gateAvailable: true)
        XCTAssertTrue(a.canInteract)
        XCTAssertNil(a.statusMessage)
    }

    func testMacGateErrorTakesStatusButSocketGatesInteract() {
        let down = GateAskActionCopy.macGateAffordance(
            gateAvailable: false,
            errorText: "Write to gate failed — retry"
        )
        XCTAssertFalse(down.canInteract)
        XCTAssertEqual(down.statusMessage, "Write to gate failed — retry")

        let up = GateAskActionCopy.macGateAffordance(
            gateAvailable: true,
            errorText: "Write to gate failed — retry"
        )
        XCTAssertTrue(up.canInteract)
        XCTAssertEqual(up.statusMessage, "Write to gate failed — retry")
    }

    func testPhoneWiresSharedCopyNotConfirmVerb() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let phone = (try? String(
            contentsOf: root.appendingPathComponent("iOS/Sources/ShannonPhone/HomeView.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(phone.contains("GateAskActionCopy"), "phone must use shared affordance")
        XCTAssertTrue(phone.contains("companionAffordance") || phone.contains("GateAskActionCopy.approve"))
        // Dual-OS Confirm verb must not remain on primary answer buttons.
        XCTAssertFalse(
            phone.contains("title: \"Confirm\""),
            "phone must use Approve (Mac parity), not Confirm"
        )

        let mac = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/ShannonPill/GateAskCard.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            mac.contains("GateAskActionCopy") || mac.contains("macGateAffordance"),
            "Mac GateAskCard must share offline/action copy"
        )
    }

    /// UX-014: watch gate Approve/Deny/Sending share Core tokens.
    func testWatchGateWiresSharedApproveDenySending() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let watch = (try? String(
            contentsOf: root.appendingPathComponent(
                "watchOS/Sources/ShannonWatch/WatchRootView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(watch.contains("GateAskActionCopy.approve"))
        XCTAssertTrue(watch.contains("GateAskActionCopy.deny"))
        XCTAssertTrue(watch.contains("GateAskActionCopy.sending"))
        XCTAssertFalse(
            watch.contains("gateButton(\"Approve\""),
            "watch must not hard-code Approve string"
        )
        XCTAssertFalse(
            watch.contains("gateButton(\"Deny\""),
            "watch must not hard-code Deny string"
        )
        // UX-020: empty list uses content(isPhoneReachable:) — not always idle.
        XCTAssertTrue(
            watch.contains("CompanionEmptyStateCopy"),
            "watch empty agent list must use shared empty copy"
        )
        XCTAssertTrue(
            watch.contains("isPhoneReachable"),
            "watch empty list must consider phone reachability"
        )
        XCTAssertFalse(
            watch.contains("Text(\"No agents\")"),
            "watch must not hard-code dual-OS No agents empty string"
        )
        // UX-023: gate status sent/queued share Core tokens with face.
        XCTAssertTrue(watch.contains("GateAskActionCopy.sent"))
        XCTAssertTrue(watch.contains("GateAskActionCopy.queuedForPhone"))
        XCTAssertFalse(
            watch.contains("Text(\"Sent ✓\")"),
            "gate status must not hard-code dual sent string"
        )
        // UX-033: phone-away chip shares Core token.
        XCTAssertTrue(
            watch.contains("GateAskActionCopy.phoneAwayChip"),
            "watch gate must use GateAskActionCopy.phoneAwayChip"
        )
        XCTAssertFalse(
            watch.contains("\"iPhone away\""),
            "watch must not hard-code dual iPhone away chip string"
        )
    }

    /// UX-023: face DeliveryRow must not dual-fork sending/sent/queued vs gate.
    func testWatchFaceDeliveryWiresSharedCopy() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let face = (try? String(
            contentsOf: root.appendingPathComponent(
                "watchOS/Sources/ShannonWatch/ShannonFaceView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(face.contains("GateAskActionCopy.sending"))
        XCTAssertTrue(face.contains("GateAskActionCopy.sent"))
        XCTAssertTrue(face.contains("GateAskActionCopy.queuedForPhone"))
        XCTAssertFalse(
            face.contains("\"Sending answer"),
            "face must not hard-code dual Sending answer prose"
        )
        XCTAssertFalse(
            face.contains("\"Answer sent\""),
            "face must not hard-code dual Answer sent string"
        )
        XCTAssertFalse(
            face.contains("\"Answer queued"),
            "face must not hard-code dual Answer queued string"
        )
    }

    /// UX-013: menu-bar GateInlineCard shares tokens with GateAskCard / phone / pad.
    func testMacGateInlineCardWiresSharedCopy() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let inline = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/ShannonPill/GateInlineCard.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            inline.contains("GateAskActionCopy"),
            "GateInlineCard must use GateAskActionCopy"
        )
        XCTAssertTrue(inline.contains("GateAskActionCopy.needsApproval"))
        XCTAssertTrue(inline.contains("GateAskActionCopy.approve") || inline.contains("a.approveLabel"))
        XCTAssertTrue(inline.contains("GateAskActionCopy.deny") || inline.contains("a.denyLabel"))
        XCTAssertTrue(
            inline.contains("macGateAffordance"),
            "GateInlineCard must use macGateAffordance when hub socket is down (UX-036)"
        )
        XCTAssertTrue(
            inline.contains("gateAvailable"),
            "GateInlineCard must take gateAvailable (UX-036)"
        )
        XCTAssertFalse(
            inline.contains("Text(\"needs approval\")"),
            "GateInlineCard must not hard-code needs-approval capsule"
        )
        XCTAssertFalse(
            inline.contains("answerButton(\"Approve\""),
            "GateInlineCard must not hard-code Approve string"
        )
    }

    /// UX-012: iPad must not hard-code dual-OS "Confirm" on primary approve actions.
    func testPadWiresApproveNotConfirmVerb() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let surfaces = [
            "iPad/Sources/ShannonPad/Views/AgentDetailView.swift",
            "iPad/Sources/ShannonPad/Views/NotificationPanelView.swift",
            "iPad/Sources/ShannonPad/Views/GateCardView.swift",
            "iPad/Sources/ShannonPad/ViewModels/PaletteCatalogue.swift",
        ]
        for rel in surfaces {
            let text = (try? String(
                contentsOf: root.appendingPathComponent(rel),
                encoding: .utf8
            )) ?? ""
            XCTAssertTrue(
                text.contains("GateAskActionCopy"),
                "\(rel) must use GateAskActionCopy"
            )
            // Forbid hard-coded UI strings only (not prose comments).
            XCTAssertFalse(
                text.contains("Label(\"Confirm\""),
                "\(rel) must not hard-code Label Confirm"
            )
            XCTAssertFalse(
                text.contains("title: \"Confirm\""),
                "\(rel) must not hard-code title Confirm"
            )
            XCTAssertTrue(
                text.contains("GateAskActionCopy.approve")
                    || text.contains("GateAskActionCopy.deny"),
                "\(rel) must reference shared approve/deny tokens"
            )
        }
    }

    /// UX-018: iPad GateCard + hub answers use companionAffordance (phone parity).
    func testPadGateCardWiresCompanionAffordanceOffline() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let card = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/GateCardView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            card.contains("companionAffordance"),
            "GateCardView must use companionAffordance"
        )
        // UX-034: Gate Activity past-tense outcomes share Core tokens.
        XCTAssertTrue(
            card.contains("GateAskActionCopy.outcomeLabel"),
            "Gate Activity must use GateAskActionCopy.outcomeLabel"
        )
        XCTAssertFalse(
            card.contains("? \"approved\" : \"denied\""),
            "Gate Activity must not hard-code dual approved/denied ternary"
        )
        XCTAssertTrue(
            card.contains("lastError") || card.contains("hub.store.lastError"),
            "GateCardView must pass hub lastError into affordance"
        )
        XCTAssertTrue(
            card.contains(".disabled(!a.canInteract)") || card.contains("disabled(!a.canInteract)"),
            "GateCardView must disable Approve/Deny when cannot interact"
        )
        XCTAssertTrue(
            card.contains("statusMessage"),
            "GateCardView must surface offline/expired status"
        )

        let vm = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/ViewModels/AgentHubViewModel.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            vm.contains("companionAffordance"),
            "AgentHubViewModel.answer must guard with companionAffordance"
        )
    }

    /// UX-048: ⌘A/⌘D disabled via shared canInteractWithOldestPending helper.
    func testPadConfirmationMenuWiresCanInteractWithOldestPending() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let app = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/ShannonPadApp.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            app.contains("canInteractWithOldestPending"),
            "ShannonPadApp Confirmation menu must use canInteractWithOldestPending (UX-048)"
        )
        XCTAssertFalse(
            app.contains(".disabled(hub.pendingConfirmations.isEmpty)"),
            "Confirmation menu must not disable only on empty pending (offline would stay live)"
        )

        let vm = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/ViewModels/AgentHubViewModel.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            vm.contains("canInteractWithOldestPending"),
            "AgentHubViewModel must expose canInteractWithOldestPending"
        )
        XCTAssertTrue(
            vm.contains("companionAffordance"),
            "canInteractWithOldestPending must resolve via companionAffordance"
        )

        let palette = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/ViewModels/PaletteCatalogue.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            palette.contains("canInteractWithOldestPending"),
            "PaletteCatalogue should share canInteractWithOldestPending for Approve/Deny"
        )
    }

    /// UX-047: docking Cancel/Export must not be silent empty closures.
    func testPadDockingCancelExportNotSilentNoOps() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let vm = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/ViewModels/AgentHubViewModel.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            vm.contains("requestDockingCancel") && vm.contains("requestDockingExportCSV"),
            "AgentHubViewModel must expose honest docking cancel/export requests"
        )
        XCTAssertTrue(
            vm.contains("not wired yet"),
            "docking cancel/export must post honest not-wired-yet status"
        )

        for rel in [
            "iPad/Sources/ShannonPad/Views/DashboardGridView.swift",
            "iPad/Sources/ShannonPad/Views/AgentDetailView.swift",
        ] {
            let text = (try? String(
                contentsOf: root.appendingPathComponent(rel),
                encoding: .utf8
            )) ?? ""
            XCTAssertTrue(
                text.contains("requestDockingCancel"),
                "\(rel) must wire onCancel to requestDockingCancel"
            )
            XCTAssertTrue(
                text.contains("requestDockingExportCSV"),
                "\(rel) must wire onExportCSV to requestDockingExportCSV"
            )
            XCTAssertFalse(
                text.contains("onCancel: {}"),
                "\(rel) must not pass silent empty onCancel"
            )
            XCTAssertFalse(
                text.contains("onExportCSV: {}"),
                "\(rel) must not pass silent empty onExportCSV"
            )
        }
    }

    /// PET E6: PetRail is deferred scaffold — not mounted in hub entry points.
    func testPadPetRailDocumentedUnmounted() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let app = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/ShannonPadApp.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            app.contains("PET E6") || app.contains("not mounted"),
            "ShannonPadApp must document PetRail deferred / unmounted (PET E6)"
        )
        // Deferred comments may name types; forbid actual mount/inject patterns.
        XCTAssertFalse(
            app.contains("PetRailView("),
            "ShannonPadApp must not instantiate PetRailView"
        )
        XCTAssertFalse(
            app.contains(".environment(") && app.contains("PetStore"),
            "ShannonPadApp must not inject PetStore into the environment"
        )
        XCTAssertFalse(
            app.contains("PetStore.shared") || app.contains("PetStore()"),
            "ShannonPadApp must not construct/bind PetStore"
        )

        let hub = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/AgentHubView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertFalse(
            hub.contains("PetRailView") || hub.contains("PetStore"),
            "AgentHubView must not mount PetRail (PET E6 deferred)"
        )

        let rail = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/PetRailView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            rail.contains("PET E6") || rail.contains("not mounted"),
            "PetRailView must document that it is not mounted"
        )
    }

    /// UX-044: phone AirPods answer TTS must use outcome family, not Confirmed/Denied duals.
    func testPhoneAnswerTTSUsesOutcomeLabelNotConfirmedDenied() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let model = (try? String(
            contentsOf: root.appendingPathComponent(
                "iOS/Sources/ShannonPhone/PhoneModel.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertFalse(model.isEmpty, "PhoneModel.swift must be readable")
        XCTAssertTrue(
            model.contains("GateAskActionCopy.outcomeLabel"),
            "PhoneModel.answer must announce via GateAskActionCopy.outcomeLabel (UX-044)"
        )
        XCTAssertFalse(
            model.contains("\"Confirmed\""),
            "PhoneModel must not hard-code Confirmed TTS"
        )
        XCTAssertFalse(
            model.contains("\"Denied\""),
            "PhoneModel must not hard-code Denied TTS"
        )
    }

    /// UX-021: pad detail + notification panel disable when hub offline (not GateCard only).
    func testPadDetailAndNotificationWireCompanionAffordance() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let detail = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/AgentDetailView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            detail.contains("companionAffordance"),
            "AgentDetailView must use companionAffordance"
        )
        XCTAssertTrue(
            detail.contains("disabled(!a.canInteract)") || detail.contains(".disabled(!a.canInteract)"),
            "AgentDetailView must disable Approve/Deny when cannot interact"
        )
        XCTAssertTrue(
            detail.contains("statusMessage"),
            "AgentDetailView must surface offline/expired status"
        )

        let panel = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/NotificationPanelView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            panel.contains("companionAffordance"),
            "NotificationPanelView must use companionAffordance"
        )
        XCTAssertTrue(
            panel.contains("lastError"),
            "NotificationPanelView must accept lastError"
        )
        XCTAssertTrue(
            panel.contains("disabled(!a.canInteract)") || panel.contains(".disabled(!a.canInteract)"),
            "NotificationPanelView must disable Approve/Deny when cannot interact"
        )

        let hub = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/AgentHubView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            hub.contains("lastError: hub.store.lastError"),
            "AgentHubView must pass store.lastError into NotificationPanelView"
        )
    }

    /// UX-051: rectangular complication must wire Core gate-glance — no hard-coded Shannon asks.
    func testWatchRectangularComplicationWiresGateGlanceHeader() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let complication = (try? String(
            contentsOf: root.appendingPathComponent(
                "watchOS/Sources/ShannonWatchComplication/ShannonComplication.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertFalse(complication.isEmpty, "ShannonComplication.swift must be readable")
        XCTAssertTrue(
            complication.contains("GateAskActionCopy.gateGlanceHeader")
                || complication.contains("GateAskActionCopy.gateGlanceTitle"),
            "rectangular complication must use GateAskActionCopy gate-glance token (UX-051)"
        )
        XCTAssertFalse(
            complication.contains("\"Shannon asks\""),
            "complication must not hard-code dual Shannon asks string"
        )
        XCTAssertFalse(
            complication.contains("\"Shannon asks ("),
            "complication must not hard-code dual Shannon asks (N) string"
        )
    }

    /// UX-027: Mac menu-bar roster gate hint + status-item brand a11y use Core tokens.
    func testMacMenuBarRosterWiresRosterApproveHint() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let roster = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/ShannonPill/MenuBarAgentRoster.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            roster.contains("GateAskActionCopy.rosterApproveHint"),
            "menu-bar roster must use GateAskActionCopy.rosterApproveHint"
        )
        XCTAssertTrue(
            roster.contains("GateAskActionCopy.rosterApproveAccessibility"),
            "menu-bar roster a11y must use rosterApproveAccessibility"
        )
        XCTAssertFalse(
            roster.contains("Text(\"Gate · approve\")"),
            "menu-bar roster must not hard-code dual Gate · approve string"
        )
        XCTAssertFalse(
            roster.contains("\"Gate approve available\""),
            "menu-bar roster must not hard-code dual Gate approve a11y string"
        )

        let menuBar = (try? String(
            contentsOf: root.appendingPathComponent(
                "Pill/Sources/ShannonPill/MenuBarController.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            menuBar.contains("CompanionFocusCopy.quietShort"),
            "menu-bar status symbol a11y must use CompanionFocusCopy.quietShort"
        )
        XCTAssertFalse(
            menuBar.contains("accessibilityDescription: \"Shannon\""),
            "menu-bar must not hard-code dual Shannon a11y description"
        )
    }
}
