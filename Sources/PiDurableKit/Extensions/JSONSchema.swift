import Foundation

/// A JSON Schema describing tool parameters.
///
/// ```swift
/// let parameters: JSONSchema = .object([
///     "city": .string("The city to look up"),
///     "unit": .string(enum: ["celsius", "fahrenheit"]).optional,
/// ])
/// ```
public struct JSONSchema: Sendable, Hashable, Encodable {
    /// The schema as JSON.
    public var json: JSONObject
    /// Whether the property this schema describes may be omitted. Only meaningful inside ``object(_:description:)``.
    public var isOptional = false

    public init(_ json: JSONObject) {
        self.json = json
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object(json).encode(to: encoder)
    }

    /// The same schema, as an optional property of an object.
    public var optional: JSONSchema {
        var copy = self
        copy.isOptional = true
        return copy
    }

    /// The same schema with a description.
    public func description(_ text: String) -> JSONSchema {
        var copy = self
        copy.json["description"] = .string(text)
        return copy
    }

    /// An object with these properties. Properties are required unless marked ``optional``.
    public static func object(_ properties: KeyValuePairs<String, JSONSchema> = [:], description: String? = nil) -> JSONSchema {
        var json: JSONObject = ["type": "object"]
        var values: JSONObject = [:]
        var required: [JSONValue] = []
        for (name, schema) in properties {
            values[name] = .object(schema.json)
            if !schema.isOptional { required.append(.string(name)) }
        }
        json["properties"] = .object(values)
        if !required.isEmpty { json["required"] = .array(required) }
        if let description { json["description"] = .string(description) }
        return JSONSchema(json)
    }

    public static func string(_ description: String? = nil, enum values: [String]? = nil) -> JSONSchema {
        var json: JSONObject = ["type": "string"]
        if let description { json["description"] = .string(description) }
        if let values { json["enum"] = .array(values.map(JSONValue.string)) }
        return JSONSchema(json)
    }

    public static func number(_ description: String? = nil, minimum: Double? = nil, maximum: Double? = nil) -> JSONSchema {
        var json: JSONObject = ["type": "number"]
        if let description { json["description"] = .string(description) }
        if let minimum { json["minimum"] = .number(minimum) }
        if let maximum { json["maximum"] = .number(maximum) }
        return JSONSchema(json)
    }

    public static func integer(_ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> JSONSchema {
        var json: JSONObject = ["type": "integer"]
        if let description { json["description"] = .string(description) }
        if let minimum { json["minimum"] = .number(Double(minimum)) }
        if let maximum { json["maximum"] = .number(Double(maximum)) }
        return JSONSchema(json)
    }

    public static func boolean(_ description: String? = nil) -> JSONSchema {
        var json: JSONObject = ["type": "boolean"]
        if let description { json["description"] = .string(description) }
        return JSONSchema(json)
    }

    public static func array(of items: JSONSchema, description: String? = nil) -> JSONSchema {
        var json: JSONObject = ["type": "array", "items": .object(items.json)]
        if let description { json["description"] = .string(description) }
        return JSONSchema(json)
    }

    public static var string: JSONSchema { string() }
    public static var number: JSONSchema { number() }
    public static var integer: JSONSchema { integer() }
    public static var boolean: JSONSchema { boolean() }
}
