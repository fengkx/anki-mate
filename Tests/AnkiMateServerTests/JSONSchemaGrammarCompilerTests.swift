import XCTest
@testable import AnkiMateServer
import AnkiMateRPC

final class JSONSchemaGrammarCompilerTests: XCTestCase {
    func testCompilesStructuredObjectSchema() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("full_spelling"), .string("targeted_letter_cloze")]),
                ]),
                "front": .object([
                    "type": .string("string"),
                    "maxLength": .number(120),
                ]),
                "hint": .object([
                    "type": .string("string"),
                    "maxLength": .number(40),
                ]),
            ]),
            "required": .array([.string("mode"), .string("front")]),
            "additionalProperties": .bool(false),
        ])

        let grammar = try JSONSchemaGrammarCompiler().compileRootGrammar(from: schema)

        XCTAssertTrue(grammar.contains("root ::= ws root_value ws"))
        XCTAssertTrue(grammar.contains("\"mode\""))
        XCTAssertTrue(grammar.contains("\"front\""))
        XCTAssertTrue(grammar.contains("full_spelling"))
        XCTAssertTrue(grammar.contains("targeted_letter_cloze"))
    }

    func testRejectsUnsupportedAdditionalPropertiesTrue() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object(["type": .string("string")]),
            ]),
            "additionalProperties": .bool(true),
        ])

        XCTAssertThrowsError(try JSONSchemaGrammarCompiler().compileRootGrammar(from: schema)) { error in
            XCTAssertEqual(
                error as? JSONSchemaGrammarCompilerError,
                .unsupportedKeyword("additionalProperties=true")
            )
        }
    }

    func testRejectsUnsupportedKeywords() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    "pattern": .string("[a-z]+"),
                ]),
            ]),
        ])

        XCTAssertThrowsError(try JSONSchemaGrammarCompiler().compileRootGrammar(from: schema)) { error in
            XCTAssertEqual(error as? JSONSchemaGrammarCompilerError, .unsupportedKeyword("pattern"))
        }
    }

    func testInferenceEngineFallsBackToGenericJSONWhenSchemaUnsupportedAndNonStrict() throws {
        let engine = InferenceEngine()
        let format = LLMResponseFormat(
            kind: .jsonSchema,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("string"),
                        "pattern": .string("[a-z]+"),
                    ]),
                ]),
            ]),
            strict: false
        )

        let grammar = try engine.resolvedGrammarString(for: format)
        XCTAssertEqual(grammar, InferenceEngine.genericJSONGrammar)
    }

    func testInferenceEngineRejectsUnsupportedStrictSchema() {
        let engine = InferenceEngine()
        let format = LLMResponseFormat(
            kind: .jsonSchema,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("string"),
                        "pattern": .string("[a-z]+"),
                    ]),
                ]),
            ]),
            strict: true
        )

        XCTAssertThrowsError(try engine.resolvedGrammarString(for: format)) { error in
            guard case InferenceError.unsupportedResponseFormat(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("pattern"))
        }
    }
}
