import Foundation

/// An arbitrary JSON value, as stored by pi-durable in entries, documents, and tool details.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Encodes any `Encodable` value as JSON.
    public init(encoding value: some Encodable) throws {
        self = try decodeJSON(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Decodes this JSON value as `T`.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try decodeJSON(T.self, from: JSONEncoder().encode(self))
    }

    /// Compact JSON text.
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        // Fast path: read the node straight from the parsed JSON (see `decodeJSON`), instead of probing each type
        // through Codable, which throws (and builds an error) for every type a value is not.
        if let raw = decoder.userInfo[.rawJSON] as? RawJSON, let node = raw.node(at: decoder.codingPath) {
            self = JSONValue(foundation: node)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString }
}

/// A JSON object.
public typealias JSONObject = [String: JSONValue]

/// Decodes `data`, letting `JSONValue`s (and the raw JSON kept by messages) be read directly from a one-time
/// `JSONSerialization` parse, which is many times faster than decoding untyped JSON through `Codable`.
func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.userInfo[.rawJSON] = RawJSON(data)
    return try decoder.decode(type, from: data)
}

extension CodingUserInfoKey {
    static let rawJSON = CodingUserInfoKey(rawValue: "PiDurableKit.rawJSON")!
}

/// The data being decoded, parsed on first use, for looking up the node at a decoder's coding path.
final class RawJSON: @unchecked Sendable {
    private let data: Data
    private var parsed = false
    private var root: Any?

    init(_ data: Data) { self.data = data }

    func node(at path: [any CodingKey]) -> Any? {
        if !parsed {
            parsed = true
            root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        var node = root
        // NSArray and NSDictionary, not Swift collections: bridging would copy a container at every step.
        for key in path {
            if let index = key.intValue, let array = node as? NSArray {
                guard index < array.count else { return nil }
                node = array.object(at: index)
            } else if let object = node as? NSDictionary {
                guard let next = object.object(forKey: key.stringValue) else { return nil }
                node = next
            } else {
                return nil
            }
        }
        return node
    }
}

extension JSONValue {
    /// Converts a `JSONSerialization` value.
    init(foundation value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as NSArray:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let object as NSDictionary:
            var result: JSONObject = [:]
            result.reserveCapacity(object.count)
            for (key, value) in object {
                if let key = key as? String { result[key] = JSONValue(foundation: value) }
            }
            self = .object(result)
        default:
            self = .null
        }
    }
}
