import Foundation
import AnkiMateRPC

enum JSONSchemaGrammarCompilerError: LocalizedError, Equatable {
    case invalidSchema(String)
    case unsupportedKeyword(String)
    case unsupportedShape(String)

    var errorDescription: String? {
        switch self {
        case .invalidSchema(let message):
            return "Invalid JSON Schema: \(message)"
        case .unsupportedKeyword(let keyword):
            return "Unsupported JSON Schema keyword: \(keyword)"
        case .unsupportedShape(let message):
            return "Unsupported JSON Schema shape: \(message)"
        }
    }
}

struct JSONSchemaGrammarCompiler {
    func compileRootGrammar(from schema: JSONValue) throws -> String {
        let normalized = try normalizeRootSchema(schema)
        var builder = GrammarBuilder()
        let rootRule = try compile(schema: normalized, suggestedName: "root_value", into: &builder)
        return builder.render(rootRule: rootRule)
    }

    private func normalizeRootSchema(_ schema: JSONValue) throws -> JSONValue {
        guard case .object(let object) = schema else {
            throw JSONSchemaGrammarCompilerError.invalidSchema("root schema must be an object")
        }
        if let type = string(in: object, key: "type"), type == "json_schema" {
            if let wrapped = object["json_schema"] {
                return try normalizeRootSchema(wrapped)
            }
            throw JSONSchemaGrammarCompilerError.invalidSchema("json_schema wrapper must contain json_schema")
        }
        if let wrapped = object["schema"] {
            return wrapped
        }
        return schema
    }

    private func compile(
        schema: JSONValue,
        suggestedName: String,
        into builder: inout GrammarBuilder
    ) throws -> String {
        guard case .object(let object) = schema else {
            throw JSONSchemaGrammarCompilerError.invalidSchema("schema for \(suggestedName) must be an object")
        }

        try validateSupportedKeys(object)

        if let const = object["const"] {
            return builder.define(rule: suggestedName, body: literal(for: const))
        }

        if let enumValues = object["enum"] {
            guard case .array(let values) = enumValues, values.isEmpty == false else {
                throw JSONSchemaGrammarCompilerError.invalidSchema("enum must be a non-empty array")
            }
            let body = values.map(literal(for:)).joined(separator: " | ")
            return builder.define(rule: suggestedName, body: body)
        }

        guard let type = string(in: object, key: "type") else {
            throw JSONSchemaGrammarCompilerError.unsupportedShape("schema for \(suggestedName) must declare a string type")
        }

        switch type {
        case "object":
            return try compileObject(object, suggestedName: suggestedName, into: &builder)
        case "array":
            return try compileArray(object, suggestedName: suggestedName, into: &builder)
        case "string":
            return try compileString(object, suggestedName: suggestedName, into: &builder)
        case "integer":
            return try compileInteger(object, suggestedName: suggestedName, into: &builder)
        case "number":
            return try compileNumber(object, suggestedName: suggestedName, into: &builder)
        case "boolean":
            return builder.define(rule: suggestedName, body: "\"true\" | \"false\"")
        case "null":
            return builder.define(rule: suggestedName, body: "\"null\"")
        default:
            throw JSONSchemaGrammarCompilerError.unsupportedShape("unsupported type '\(type)'")
        }
    }

    private func compileObject(
        _ object: [String: JSONValue],
        suggestedName: String,
        into builder: inout GrammarBuilder
    ) throws -> String {
        let propertiesValue = object["properties"] ?? .object([:])
        guard case .object(let properties) = propertiesValue else {
            throw JSONSchemaGrammarCompilerError.invalidSchema("properties must be an object")
        }
        let propertyOrder = Array(properties.keys)
        let requiredNames = try requiredSet(in: object)
        let additionalProperties = bool(in: object, key: "additionalProperties") ?? false
        if additionalProperties {
            throw JSONSchemaGrammarCompilerError.unsupportedKeyword("additionalProperties=true")
        }

        var propertyRules: [(name: String, valueRule: String)] = []
        for propertyName in propertyOrder {
            guard let propertySchema = properties[propertyName] else { continue }
            let ruleName = "\(suggestedName)_\(sanitize(propertyName))"
            let valueRule = try compile(schema: propertySchema, suggestedName: ruleName, into: &builder)
            propertyRules.append((propertyName, valueRule))
        }

        let body = try buildObjectBody(
            suggestedName: suggestedName,
            propertyRules: propertyRules,
            requiredNames: requiredNames
        )
        return builder.define(rule: suggestedName, body: body)
    }

    private func buildObjectBody(
        suggestedName: String,
        propertyRules: [(name: String, valueRule: String)],
        requiredNames: Set<String>
    ) throws -> String {
        if propertyRules.isEmpty {
            return "\"{\" ws \"}\""
        }

        let allOptional = propertyRules.allSatisfy { requiredNames.contains($0.name) == false }
        if allOptional {
            throw JSONSchemaGrammarCompilerError.unsupportedShape("object with only optional properties is not supported")
        }

        var variants: [String] = []
        let totalMasks = 1 << propertyRules.count
        for mask in 0..<totalMasks {
            var included: [(name: String, valueRule: String)] = []
            var isValid = true
            for (index, property) in propertyRules.enumerated() {
                let include = (mask & (1 << index)) != 0
                if requiredNames.contains(property.name), include == false {
                    isValid = false
                    break
                }
                if include {
                    included.append(property)
                }
            }
            guard isValid, included.isEmpty == false else { continue }

            let pairs = included.enumerated().map { index, property in
                let prefix = index == 0 ? "" : "\",\" ws "
                return "\(prefix)\(quoted(property.name)) ws \":\" ws \(property.valueRule) ws"
            }
            variants.append("\"{\" ws \(pairs.joined()) \"}\"")
        }

        guard variants.isEmpty == false else {
            throw JSONSchemaGrammarCompilerError.unsupportedShape("object variant set for \(suggestedName) is empty")
        }

        return variants.joined(separator: " | ")
    }

    private func compileArray(
        _ object: [String: JSONValue],
        suggestedName: String,
        into builder: inout GrammarBuilder
    ) throws -> String {
        guard let items = object["items"] else {
            throw JSONSchemaGrammarCompilerError.unsupportedKeyword("array.items")
        }
        let itemRule = try compile(schema: items, suggestedName: "\(suggestedName)_item", into: &builder)
        let minItems = try int(in: object, key: "minItems") ?? 0
        let maxItems = try int(in: object, key: "maxItems")
        if let maxItems, maxItems < minItems {
            throw JSONSchemaGrammarCompilerError.invalidSchema("maxItems must be >= minItems")
        }
        if minItems > 8 || (maxItems ?? 8) > 8 {
            throw JSONSchemaGrammarCompilerError.unsupportedKeyword("minItems/maxItems > 8")
        }

        let upperBound = maxItems ?? max(minItems, 3)
        var variants: [String] = []
        for count in minItems...upperBound {
            if count == 0 {
                variants.append("\"[\" ws \"]\"")
                continue
            }
            let elements = (0..<count).map { index in
                index == 0 ? "\(itemRule) ws" : "\",\" ws \(itemRule) ws"
            }
            variants.append("\"[\" ws \(elements.joined()) \"]\"")
        }
        return builder.define(rule: suggestedName, body: variants.joined(separator: " | "))
    }

    private func compileString(
        _ object: [String: JSONValue],
        suggestedName: String,
        into builder: inout GrammarBuilder
    ) throws -> String {
        let minLength = try int(in: object, key: "minLength") ?? 0
        let maxLength = try int(in: object, key: "maxLength")
        if minLength > 64 || (maxLength ?? 64) > 64 {
            throw JSONSchemaGrammarCompilerError.unsupportedKeyword("minLength/maxLength > 64")
        }

        let charRule = "json_char"
        let body: String
        if let maxLength {
            if maxLength < minLength {
                throw JSONSchemaGrammarCompilerError.invalidSchema("maxLength must be >= minLength")
            }
            if minLength == maxLength {
                let chars = Array(repeating: charRule, count: minLength).joined(separator: " ")
                body = "\"\\\"\" \(chars) \"\\\"\""
            } else {
                let optionalCount = maxLength - minLength
                let requiredChars = Array(repeating: charRule, count: minLength)
                let optionalChars = Array(repeating: "(\(charRule))?", count: optionalCount)
                let sequence = (requiredChars + optionalChars).joined(separator: " ")
                body = "\"\\\"\" \(sequence) \"\\\"\""
            }
        } else if minLength == 0 {
            body = "json_string"
        } else {
            let requiredChars = Array(repeating: charRule, count: minLength).joined(separator: " ")
            body = "\"\\\"\" \(requiredChars) \(charRule)* \"\\\"\""
        }
        return builder.define(rule: suggestedName, body: body)
    }

    private func compileInteger(
        _ object: [String: JSONValue],
        suggestedName: String,
        into builder: inout GrammarBuilder
    ) throws -> String {
        if object["minimum"] != nil || object["maximum"] != nil {
            throw JSONSchemaGrammarCompilerError.unsupportedKeyword("minimum/maximum")
        }
        return builder.define(rule: suggestedName, body: "integer")
    }

    private func compileNumber(
        _ object: [String: JSONValue],
        suggestedName: String,
        into builder: inout GrammarBuilder
    ) throws -> String {
        if object["minimum"] != nil || object["maximum"] != nil {
            throw JSONSchemaGrammarCompilerError.unsupportedKeyword("minimum/maximum")
        }
        return builder.define(rule: suggestedName, body: "number")
    }

    private func validateSupportedKeys(_ object: [String: JSONValue]) throws {
        let supported = Set([
            "type", "properties", "required", "items", "enum", "const",
            "additionalProperties", "minItems", "maxItems",
            "minLength", "maxLength", "schema", "json_schema",
        ])
        let unsupported = object.keys.filter { supported.contains($0) == false }
        if let first = unsupported.sorted().first {
            throw JSONSchemaGrammarCompilerError.unsupportedKeyword(first)
        }
    }

    private func requiredSet(in object: [String: JSONValue]) throws -> Set<String> {
        guard let required = object["required"] else {
            return []
        }
        guard case .array(let values) = required else {
            throw JSONSchemaGrammarCompilerError.invalidSchema("required must be an array")
        }
        var result = Set<String>()
        for value in values {
            guard case .string(let name) = value else {
                throw JSONSchemaGrammarCompilerError.invalidSchema("required entries must be strings")
            }
            result.insert(name)
        }
        return result
    }

    private func literal(for value: JSONValue) -> String {
        switch value {
        case .string(let string):
            return quoted(string)
        case .number(let number):
            return quoted(render(number))
        case .bool(let bool):
            return quoted(bool ? "true" : "false")
        case .null:
            return quoted("null")
        case .array, .object:
            return quoted(renderJSON(value))
        }
    }

    private func render(_ number: Double) -> String {
        if number.rounded(.towardZero) == number {
            return String(Int(number))
        }
        return String(number)
    }

    private func renderJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func string(in object: [String: JSONValue], key: String) -> String? {
        guard let value = object[key] else { return nil }
        guard case .string(let string) = value else { return nil }
        return string
    }

    private func bool(in object: [String: JSONValue], key: String) -> Bool? {
        guard let value = object[key] else { return nil }
        guard case .bool(let bool) = value else { return nil }
        return bool
    }

    private func int(in object: [String: JSONValue], key: String) throws -> Int? {
        guard let value = object[key] else { return nil }
        guard case .number(let number) = value else {
            throw JSONSchemaGrammarCompilerError.invalidSchema("\(key) must be numeric")
        }
        let intValue = Int(number)
        guard Double(intValue) == number else {
            throw JSONSchemaGrammarCompilerError.invalidSchema("\(key) must be an integer")
        }
        return intValue
    }

    private func sanitize(_ name: String) -> String {
        let sanitized = name.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "_"
        }
        return String(sanitized)
    }

    private func quoted(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

private struct GrammarBuilder {
    private var rules: [String: String] = [:]
    private var order: [String] = []

    mutating func define(rule: String, body: String) -> String {
        if rules[rule] == nil {
            order.append(rule)
        }
        rules[rule] = body
        return rule
    }

    func render(rootRule: String) -> String {
        let prelude = [
            "root ::= ws \(rootRule) ws",
            "ws ::= [ \\t\\n\\r]*",
            "json_string ::= \"\\\"\" json_char* \"\\\"\"",
            "json_char ::= [^\"\\\\\\x00-\\x1F] | \"\\\\\" ([\"\\\\/bfnrt] | \"u\" hex hex hex hex)",
            "hex ::= [0-9a-fA-F]",
            "integer ::= \"-\"? (\"0\" | [1-9] [0-9]*)",
            "number ::= integer (\".\" [0-9]+)? ([eE] [+-]? [0-9]+)?",
        ]
        let customRules: [String] = order.compactMap { rule in
            guard let body = rules[rule] else { return nil }
            return "\(rule) ::= \(body)"
        }
        return (prelude + customRules).joined(separator: "\n")
    }
}
