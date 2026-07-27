import Foundation

// MARK: - Research & clinical data (NATURaL HealthKit / ResearchKit / CareKit lineage)
//
// Pure models + consent gates for research data. Platform adapters (HealthKit on
// watchOS/iOS, CareKitStore on iOS, ResearchKit surveys on iOS) sit above this.
// There is no Apple “DrugKit” SDK — medication is CareKit-style tasks + dose events.
//
// Never put PHI / clinical values into CloudKit agent sync fields.

// MARK: Consent (ClinicalConsent)

/// Explicit opt-in for clinical / medication research-data reads.
public struct ClinicalConsent: Codable, Sendable, Equatable {
    /// Bump when privacy copy or data uses change; older grants become invalid.
    public static let currentPolicyVersion = "1.0"

    public var isGranted: Bool
    public var grantedAt: Date?
    public var revokedAt: Date?
    public var policyVersion: String?

    public init(
        isGranted: Bool = false,
        grantedAt: Date? = nil,
        revokedAt: Date? = nil,
        policyVersion: String? = nil
    ) {
        self.isGranted = isGranted
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
        self.policyVersion = policyVersion
    }

    /// True only when granted under the *current* policy version.
    public var isValidForCurrentPolicy: Bool {
        isGranted && policyVersion == Self.currentPolicyVersion
    }
}

public struct ConsentAuditEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(timestamp.timeIntervalSince1970)-\(action.rawValue)-\(detail.hashValue)" }

    public enum Action: String, Codable, Sendable {
        case grant
        case revoke
        case clinicalReadAttempt
        case clinicalReadBlocked
        case clinicalReadSuccess
        case clinicalReadFailure
        case careKitSync
        case manualEntry
        case healthKitEnable
        case surveyIngest
    }

    public let timestamp: Date
    public let action: Action
    /// No PHI — medication names / clinical values must not appear.
    public let detail: String

    public init(timestamp: Date = Date(), action: Action, detail: String) {
        self.timestamp = timestamp
        self.action = action
        self.detail = detail
    }

    public var auditString: String {
        let iso = ISO8601DateFormatter().string(from: timestamp)
        return "[\(iso)] consent.\(action.rawValue): \(detail)"
    }
}

/// UserDefaults-backed clinical consent store (injectable for tests).
public final class ClinicalConsentStore: @unchecked Sendable {
    public static let shared = ClinicalConsentStore()

    private let defaults: UserDefaults
    private let consentKey = "shannon.clinicalConsent.v1"
    private let auditKey = "shannon.clinicalConsent.audit.v1"
    private let maxAuditEntries = 100
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var consent: ClinicalConsent {
        lock.lock()
        defer { lock.unlock() }
        return loadConsentUnlocked()
    }

    public var hasValidClinicalConsent: Bool {
        consent.isValidForCurrentPolicy
    }

    public var auditLog: [ConsentAuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadAuditUnlocked()
    }

    @discardableResult
    public func grant(at date: Date = Date()) -> ClinicalConsent {
        lock.lock()
        defer { lock.unlock() }
        let updated = ClinicalConsent(
            isGranted: true,
            grantedAt: date,
            revokedAt: nil,
            policyVersion: ClinicalConsent.currentPolicyVersion
        )
        persistUnlocked(updated)
        appendAuditUnlocked(ConsentAuditEntry(
            timestamp: date,
            action: .grant,
            detail: "user_opt_in policy=\(ClinicalConsent.currentPolicyVersion)"
        ))
        return updated
    }

    @discardableResult
    public func revoke(at date: Date = Date()) -> ClinicalConsent {
        lock.lock()
        defer { lock.unlock() }
        let previous = loadConsentUnlocked()
        let updated = ClinicalConsent(
            isGranted: false,
            grantedAt: previous.grantedAt,
            revokedAt: date,
            policyVersion: previous.policyVersion
        )
        persistUnlocked(updated)
        appendAuditUnlocked(ConsentAuditEntry(
            timestamp: date,
            action: .revoke,
            detail: "user_opt_out previousPolicy=\(previous.policyVersion ?? "none")"
        ))
        return updated
    }

    public func appendAudit(_ entry: ConsentAuditEntry) {
        lock.lock()
        defer { lock.unlock() }
        appendAuditUnlocked(entry)
    }

    /// Fail-closed gate for clinical/medication reads.
    public func allowClinicalRead(detail: String = "clinical") -> Bool {
        if hasValidClinicalConsent {
            appendAudit(ConsentAuditEntry(action: .clinicalReadSuccess, detail: detail))
            return true
        }
        appendAudit(ConsentAuditEntry(action: .clinicalReadBlocked, detail: detail))
        return false
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: consentKey)
        defaults.removeObject(forKey: auditKey)
    }

    private func loadConsentUnlocked() -> ClinicalConsent {
        guard let data = defaults.data(forKey: consentKey),
              let decoded = try? JSONDecoder().decode(ClinicalConsent.self, from: data) else {
            return ClinicalConsent()
        }
        return decoded
    }

    private func persistUnlocked(_ consent: ClinicalConsent) {
        if let data = try? JSONEncoder().encode(consent) {
            defaults.set(data, forKey: consentKey)
        }
    }

    private func loadAuditUnlocked() -> [ConsentAuditEntry] {
        guard let data = defaults.data(forKey: auditKey),
              let decoded = try? JSONDecoder().decode([ConsentAuditEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private func appendAuditUnlocked(_ entry: ConsentAuditEntry) {
        var log = loadAuditUnlocked()
        log.append(entry)
        if log.count > maxAuditEntries {
            log = Array(log.suffix(maxAuditEntries))
        }
        if let data = try? JSONEncoder().encode(log) {
            defaults.set(data, forKey: auditKey)
        }
    }
}

// MARK: Research survey (ResearchKit-style, no ORK dependency)

/// Survey instrument result normalized for research analysis (ResearchKit bridge shape).
public struct ResearchSurveyResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(timestamp.timeIntervalSince1970)-\(instrumentId)" }

    public let timestamp: Date
    public let instrumentId: String
    /// 0…1 regardless of native scale.
    public let normalizedScore: Double
    public let responses: [String: String]

    public init(
        timestamp: Date = Date(),
        instrumentId: String,
        normalizedScore: Double,
        responses: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.instrumentId = instrumentId
        self.normalizedScore = min(1, max(0, normalizedScore))
        self.responses = responses
    }
}

/// Pure ResearchKit-style survey → normalized result (no ORK UI).
public enum ResearchSurveyBridge: Sendable {
    public static func normalizeScore(_ raw: Double, from range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = max(range.lowerBound, min(range.upperBound, raw))
        return (clamped - range.lowerBound) / span
    }

    public static func processSurveyResult(
        instrumentId: String,
        stepResults: [String: String],
        scaleRange: ClosedRange<Double>,
        at date: Date = Date()
    ) -> ResearchSurveyResult {
        let numeric = stepResults.values.compactMap(Double.init)
        let raw = numeric.isEmpty ? 0 : numeric.reduce(0, +) / Double(numeric.count)
        return ResearchSurveyResult(
            timestamp: date,
            instrumentId: instrumentId,
            normalizedScore: normalizeScore(raw, from: scaleRange),
            responses: stepResults
        )
    }

    /// Pain VAS 0–10 (lower pain → higher normalized score).
    public static func processPainVAS(score: Double, at date: Date = Date()) -> ResearchSurveyResult {
        let inverted = 1.0 - (score / 10.0)
        return ResearchSurveyResult(
            timestamp: date,
            instrumentId: "pain-vas",
            normalizedScore: max(0, min(1, inverted)),
            responses: ["pain_score": String(format: "%.1f", score)]
        )
    }

    /// Mood Likert 1–5 (higher → better).
    public static func processMoodLikert(score: Int, at date: Date = Date()) -> ResearchSurveyResult {
        let normalized = Double(score - 1) / 4.0
        return ResearchSurveyResult(
            timestamp: date,
            instrumentId: "mood-likert",
            normalizedScore: max(0, min(1, normalized)),
            responses: ["mood_score": "\(score)"]
        )
    }

    /// WHO-5 raw 0–25.
    public static func processWHO5(rawScore: Int, at date: Date = Date()) -> ResearchSurveyResult {
        ResearchSurveyResult(
            timestamp: date,
            instrumentId: "well-being-5",
            normalizedScore: max(0, min(1, Double(rawScore) / 25.0)),
            responses: ["who5_raw": "\(rawScore)", "who5_pct": "\(rawScore * 4)"]
        )
    }
}

// MARK: Medication / CareKit-style adherence (no CareKitStore dependency in pure layer)

public enum MedicationDoseEvent: String, Codable, Sendable {
    case taken
    case missed
    case skipped
    case late
}

/// Local medication prescription task (CareKit OCKTask shape, pure).
public struct MedicationPrescription: Codable, Sendable, Equatable, Identifiable {
    public var id: String { taskId }
    public let medicationId: String
    public let displayName: String
    public let dosesPerDay: Int
    public let startDate: Date
    public let isActive: Bool

    public var taskId: String { MedicationResearch.taskId(for: medicationId) }

    public init(
        medicationId: String,
        displayName: String,
        dosesPerDay: Int = 1,
        startDate: Date = Date(),
        isActive: Bool = true
    ) {
        self.medicationId = medicationId
        self.displayName = displayName
        self.dosesPerDay = max(1, dosesPerDay)
        self.startDate = startDate
        self.isActive = isActive
    }
}

/// One dose outcome against a prescription (CareKit outcome shape, pure).
public struct MedicationDoseRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(timestamp.timeIntervalSince1970)-\(medicationId)-\(event.rawValue)" }
    public let medicationId: String
    public let timestamp: Date
    public let event: MedicationDoseEvent
    public let doseValue: Double?
    public let doseUnit: String?

    public init(
        medicationId: String,
        timestamp: Date = Date(),
        event: MedicationDoseEvent,
        doseValue: Double? = nil,
        doseUnit: String? = nil
    ) {
        self.medicationId = medicationId
        self.timestamp = timestamp
        self.event = event
        self.doseValue = doseValue
        self.doseUnit = doseUnit
    }
}

public enum MedicationResearch: Sendable {
    public static let taskIdPrefix = "shannon.med."

    public static func taskId(for medicationId: String) -> String {
        taskIdPrefix + medicationId
    }

    public static func isMedicationTaskId(_ taskId: String) -> Bool {
        taskId.hasPrefix(taskIdPrefix)
    }

    public static func medicationId(fromTaskId taskId: String) -> String? {
        guard isMedicationTaskId(taskId) else { return nil }
        let id = String(taskId.dropFirst(taskIdPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Adherence = taken(+late) / expected doses over `days` (expected = dosesPerDay × days).
    public static func adherence(
        prescription: MedicationPrescription,
        doses: [MedicationDoseRecord],
        days: Int = 30,
        now: Date = Date()
    ) -> Double {
        guard prescription.isActive, days > 0 else { return 0 }
        let windowStart = now.addingTimeInterval(-Double(days) * 86_400)
        let relevant = doses.filter {
            $0.medicationId == prescription.medicationId && $0.timestamp >= windowStart
        }
        let taken = relevant.filter { $0.event == .taken || $0.event == .late }.count
        let expected = max(1, prescription.dosesPerDay * days)
        return min(1, Double(taken) / Double(expected))
    }

    /// Consent-gated: returns nil when clinical consent invalid.
    public static func recordDoseIfAllowed(
        store: ClinicalConsentStore,
        medicationId: String,
        event: MedicationDoseEvent,
        doseValue: Double? = nil,
        doseUnit: String? = nil,
        at date: Date = Date()
    ) -> MedicationDoseRecord? {
        guard store.allowClinicalRead(detail: "medication_dose") else { return nil }
        return MedicationDoseRecord(
            medicationId: medicationId,
            timestamp: date,
            event: event,
            doseValue: doseValue,
            doseUnit: doseUnit
        )
    }
}

// MARK: HealthKit sample → RR / SCI

/// Pure helpers for live HealthKit samples → NATURaL SCI path.
public enum HealthResearchSamples: Sendable {
    /// Approximate RR interval (ms) from BPM: RR = 60000 / BPM.
    public static func rrMilliseconds(fromBPM bpm: Double) -> Double? {
        guard bpm.isFinite, bpm > 20, bpm < 250 else { return nil }
        return 60_000.0 / bpm
    }

    public static func rrSeries(fromBPMSeries bpms: [Double]) -> [Double] {
        bpms.compactMap { rrMilliseconds(fromBPM: $0) }
    }

    /// Run SCI when enough RR samples exist (≥ 4).
    public static func sciFromBPMSeries(
        _ bpms: [Double],
        sci: NaturalSCI = NaturalSCI()
    ) -> NaturalSCIResult? {
        let rr = rrSeries(fromBPMSeries: bpms)
        return sci.analyze(rrIntervalsMs: rr)
    }

    /// Direct RR intervals (e.g. HKHeartbeatSeries) → SCI.
    public static func sciFromRRIntervals(
        _ rrMs: [Double],
        sci: NaturalSCI = NaturalSCI()
    ) -> NaturalSCIResult? {
        sci.analyze(rrIntervalsMs: rrMs)
    }
}

// MARK: Platform availability (compile-time honesty)

/// What research frameworks this build can use (structural, not live entitlement).
public enum ResearchPlatformCapability: Sendable {
    public static var healthKitLinked: Bool {
        #if canImport(HealthKit)
        true
        #else
        false
        #endif
    }

    public static var researchKitLinked: Bool {
        #if canImport(ResearchKit)
        true
        #else
        false
        #endif
    }

    public static var careKitStoreLinked: Bool {
        #if canImport(CareKitStore)
        true
        #else
        false
        #endif
    }

    /// Operator status: which kits compile in this binary.
    public static var statusLine: String {
        var parts: [String] = []
        parts.append(healthKitLinked ? "HealthKit:linked" : "HealthKit:stub")
        parts.append(researchKitLinked ? "ResearchKit:linked" : "ResearchKit:pure-bridge")
        parts.append(careKitStoreLinked ? "CareKit:linked" : "CareKit:pure-med")
        return "Research: " + parts.joined(separator: " · ")
    }
}
