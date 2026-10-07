import Foundation

/// JSON arguments of one bridge call. Keys are sorted on encoding so that equal inputs produce equal JSON,
/// which keeps tool schemas byte-stable for provider prompt caches.
struct BridgeArguments: Encodable, ExpressibleByDictionaryLiteral, @unchecked Sendable {
    private var values: [String: any Encodable]

    init(dictionaryLiteral elements: (String, (any Encodable)?)...) {
        values = [:]
        for (key, value) in elements {
            if let value { values[key] = value }
        }
    }

    subscript(key: String) -> (any Encodable)? {
        get { values[key] }
        set { values[key] = newValue }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: AnyKey(key))
        }
    }

    static func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
