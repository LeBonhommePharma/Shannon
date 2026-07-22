import Foundation

/// The subset of CKRecord field types Shannon syncs. Keeping the snapshot
/// structs bound to this enum instead of to CKRecord means the whole
/// serialization layer can be tested on any platform, including Linux CI,
/// without a CloudKit container or an entitled process.
public enum CloudValue: Equatable, Sendable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case stringList([String])
}

/// Field bag for one record. Ordered access is never required — CloudKit
/// records are unordered key/value stores.
public typealias CloudFields = [String: CloudValue]

public enum CloudDecodeError: Error, Equatable {
    case missingField(String)
    case typeMismatch(field: String, expected: String)
    case unknownEnumValue(field: String, value: String)
}

/// Read helpers that fail loudly. A partially-decoded snapshot silently
/// showing 0/85 on the Watch is worse than no card at all, so every required
/// field throws rather than defaulting.
public extension Dictionary where Key == String, Value == CloudValue {
    func string(_ key: String) throws -> String {
        guard let v = self[key] else { throw CloudDecodeError.missingField(key) }
        guard case .string(let s) = v else {
            throw CloudDecodeError.typeMismatch(field: key, expected: "string")
        }
        return s
    }

    func double(_ key: String) throws -> Double {
        guard let v = self[key] else { throw CloudDecodeError.missingField(key) }
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: throw CloudDecodeError.typeMismatch(field: key, expected: "double")
        }
    }

    func int(_ key: String) throws -> Int {
        guard let v = self[key] else { throw CloudDecodeError.missingField(key) }
        switch v {
        case .int(let i): return i
        // CloudKit round-trips every number as NSNumber; a value written as an
        // Int can come back typed as a Double.
        case .double(let d): return Int(d.rounded())
        default: throw CloudDecodeError.typeMismatch(field: key, expected: "int")
        }
    }

    func bool(_ key: String) throws -> Bool {
        guard let v = self[key] else { throw CloudDecodeError.missingField(key) }
        switch v {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        default: throw CloudDecodeError.typeMismatch(field: key, expected: "bool")
        }
    }

    func date(_ key: String) throws -> Date {
        guard let v = self[key] else { throw CloudDecodeError.missingField(key) }
        guard case .date(let d) = v else {
            throw CloudDecodeError.typeMismatch(field: key, expected: "date")
        }
        return d
    }

    func stringList(_ key: String) throws -> [String] {
        guard let v = self[key] else { throw CloudDecodeError.missingField(key) }
        guard case .stringList(let l) = v else {
            throw CloudDecodeError.typeMismatch(field: key, expected: "stringList")
        }
        return l
    }

    // Optional variants: absent is fine, present-but-wrong-type is not.
    func optionalString(_ key: String) throws -> String? {
        self[key] == nil ? nil : try string(key)
    }

    func optionalDouble(_ key: String) throws -> Double? {
        self[key] == nil ? nil : try double(key)
    }

    func optionalInt(_ key: String) throws -> Int? {
        self[key] == nil ? nil : try int(key)
    }

    func optionalData(_ key: String) throws -> Data? {
        guard let v = self[key] else { return nil }
        guard case .data(let d) = v else {
            throw CloudDecodeError.typeMismatch(field: key, expected: "data")
        }
        return d
    }

    func optionalDate(_ key: String) throws -> Date? {
        self[key] == nil ? nil : try date(key)
    }
}

/// A snapshot type that can round-trip through one CloudKit record.
public protocol CloudSyncable: Equatable, Sendable {
    /// CKRecord.recordType. Must match the schema in the CloudKit dashboard.
    static var recordType: String { get }
    /// Stable CKRecord.ID name, so republishing overwrites in place instead of
    /// accumulating one record per poll.
    var recordName: String { get }
    var cloudFields: CloudFields { get }
    init(cloudFields: CloudFields) throws
}

public extension CloudSyncable {
    /// Round-trip check used by tests and by the publisher's debug assertions.
    func reencoded() throws -> Self {
        try Self(cloudFields: cloudFields)
    }
}

/// Field names, declared once so the Mac publisher and the phone/watch
/// consumers cannot drift apart on a typo.
public enum CloudKeys {
    public static let updatedAt = "updatedAt"
    public static let deviceName = "deviceName"
}
