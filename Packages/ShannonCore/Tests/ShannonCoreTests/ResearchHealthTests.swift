import XCTest
@testable import ShannonCore

/// Clinical consent, ResearchKit-style surveys, CareKit-style meds, HealthKit→SCI.
final class ResearchHealthTests: XCTestCase {

    private var store: ClinicalConsentStore!

    override func setUp() {
        super.setUp()
        // Isolated suite defaults so parallel tests do not share consent.
        let suite = "shannon.research.test.\(UUID().uuidString)"
        store = ClinicalConsentStore(defaults: UserDefaults(suiteName: suite)!)
        store.reset()
    }

    // MARK: Consent fail-closed

    func testDefaultConsentBlocksClinicalRead() {
        XCTAssertFalse(store.hasValidClinicalConsent)
        XCTAssertFalse(store.allowClinicalRead(detail: "test"))
        XCTAssertTrue(store.auditLog.contains { $0.action == .clinicalReadBlocked })
    }

    func testGrantEnablesClinicalReadAndRevokeBlocks() {
        _ = store.grant()
        XCTAssertTrue(store.hasValidClinicalConsent)
        XCTAssertTrue(store.allowClinicalRead(detail: "ok"))
        _ = store.revoke()
        XCTAssertFalse(store.hasValidClinicalConsent)
        XCTAssertFalse(store.allowClinicalRead(detail: "after_revoke"))
    }

    func testStalePolicyVersionInvalid() {
        // Simulate old grant without matching version.
        let old = ClinicalConsent(
            isGranted: true,
            grantedAt: Date(),
            policyVersion: "0.9"
        )
        XCTAssertFalse(old.isValidForCurrentPolicy)
        XCTAssertEqual(ClinicalConsent.currentPolicyVersion, "1.0")
    }

    // MARK: Research survey bridge

    func testPainVASNormalizesInverted() {
        let none = ResearchSurveyBridge.processPainVAS(score: 0)
        let max = ResearchSurveyBridge.processPainVAS(score: 10)
        XCTAssertEqual(none.normalizedScore, 1.0, accuracy: 1e-9)
        XCTAssertEqual(max.normalizedScore, 0.0, accuracy: 1e-9)
        XCTAssertEqual(none.instrumentId, "pain-vas")
    }

    func testMoodAndWHO5Normalize() {
        let mood = ResearchSurveyBridge.processMoodLikert(score: 5)
        XCTAssertEqual(mood.normalizedScore, 1.0, accuracy: 1e-9)
        let who = ResearchSurveyBridge.processWHO5(rawScore: 25)
        XCTAssertEqual(who.normalizedScore, 1.0, accuracy: 1e-9)
        let mid = ResearchSurveyBridge.processSurveyResult(
            instrumentId: "custom",
            stepResults: ["q1": "5"],
            scaleRange: 0...10
        )
        XCTAssertEqual(mid.normalizedScore, 0.5, accuracy: 1e-9)
    }

    // MARK: Medication adherence

    func testMedicationTaskIds() {
        let id = MedicationResearch.taskId(for: "rx-1")
        XCTAssertTrue(MedicationResearch.isMedicationTaskId(id))
        XCTAssertEqual(MedicationResearch.medicationId(fromTaskId: id), "rx-1")
        XCTAssertFalse(MedicationResearch.isMedicationTaskId("other.task"))
    }

    func testAdherencePureCalculation() {
        let rx = MedicationPrescription(
            medicationId: "rx-a", displayName: "TestMed", dosesPerDay: 1
        )
        let now = Date()
        let doses = [
            MedicationDoseRecord(medicationId: "rx-a", timestamp: now.addingTimeInterval(-86_400), event: .taken),
            MedicationDoseRecord(medicationId: "rx-a", timestamp: now.addingTimeInterval(-2 * 86_400), event: .taken),
            MedicationDoseRecord(medicationId: "rx-a", timestamp: now.addingTimeInterval(-3 * 86_400), event: .missed),
        ]
        let a = MedicationResearch.adherence(prescription: rx, doses: doses, days: 3, now: now)
        // 2 taken / 3 expected
        XCTAssertEqual(a, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testRecordDoseRequiresConsent() {
        XCTAssertNil(
            MedicationResearch.recordDoseIfAllowed(
                store: store, medicationId: "x", event: .taken
            )
        )
        _ = store.grant()
        let rec = MedicationResearch.recordDoseIfAllowed(
            store: store, medicationId: "x", event: .taken, doseValue: 10, doseUnit: "mg"
        )
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.medicationId, "x")
    }

    // MARK: BPM → RR → SCI

    func testBPMToRRAndSCIConcentratedHigherThanVariable() {
        // Steady 75 BPM → RR ~800 ms concentrated.
        let steady = Array(repeating: 75.0, count: 40)
        // Variable BPM spanning domain extremes → high entropy.
        let variable = (0..<40).map { 40.0 + Double($0) * 3.0 } // 40…157 BPM
        let sSteady = HealthResearchSamples.sciFromBPMSeries(steady)
        let sVar = HealthResearchSamples.sciFromBPMSeries(variable)
        XCTAssertNotNil(sSteady)
        XCTAssertNotNil(sVar)
        XCTAssertGreaterThan(sSteady!.sciScore, sVar!.sciScore)
        XCTAssertEqual(NaturalSCI.rrDomainMinMs, 300, accuracy: 0)
        XCTAssertEqual(NaturalSCI.rrDomainMaxMs, 1500, accuracy: 0)
    }

    func testRRFromBPMInvalidRejected() {
        XCTAssertNil(HealthResearchSamples.rrMilliseconds(fromBPM: 0))
        XCTAssertNil(HealthResearchSamples.rrMilliseconds(fromBPM: .nan))
        XCTAssertEqual(
            HealthResearchSamples.rrMilliseconds(fromBPM: 60)!,
            1000,
            accuracy: 1e-6
        )
    }

    // MARK: No PHI field names on CloudKit agent types (security)

    func testResearchModelsDoNotInjectCredentialFieldNamesOnAgentState() {
        // AgentState cloud fields must still not look like secrets.
        let fields = AgentState(id: "a", name: "n", activity: .idle).cloudFields.keys
        for f in fields {
            let low = f.lowercased()
            XCTAssertFalse(low.contains("token") || low.contains("password") || low.contains("secret"))
        }
    }

    func testPlatformCapabilityStatusLineNonEmpty() {
        let line = ResearchPlatformCapability.statusLine
        XCTAssertTrue(line.contains("HealthKit") || line.contains("Research"), line)
    }
}
