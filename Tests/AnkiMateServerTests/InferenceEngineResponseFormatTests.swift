import XCTest
@testable import AnkiMateServer
import AnkiMateRPC
import CllmLibrary

final class InferenceEngineResponseFormatTests: XCTestCase {
    func testDefaultSamplerPlanMatchesLlamaCppDefaultOrder() {
        let plan = InferenceEngine.defaultSamplerPlan(for: 0.7)

        XCTAssertEqual(plan.seed, UInt32(LLAMA_DEFAULT_SEED))
        XCTAssertEqual(
            plan.stageNames,
            [
                "penalties",
                "dry",
                "top_n_sigma",
                "top_k",
                "typical_p",
                "top_p",
                "min_p",
                "xtc",
                "temperature",
                "dist",
            ]
        )
    }

    func testDefaultSamplerPlanUsesGreedyWhenTemperatureIsNonPositive() {
        XCTAssertEqual(
            InferenceEngine.defaultSamplerPlan(for: 0).stageNames,
            ["greedy"]
        )
        XCTAssertEqual(
            InferenceEngine.defaultSamplerPlan(for: -0.1).stageNames,
            ["greedy"]
        )
    }

    func testInferenceEngineUsesBridgeForStructuredJSONSchema() throws {
        let engine = InferenceEngine()
        let format = LLMResponseFormat(
            kind: .jsonSchema,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "front": .object([
                        "type": .string("string"),
                        "minLength": .number(65),
                        "maxLength": .number(120),
                    ]),
                ]),
                "required": .array([.string("front")]),
                "additionalProperties": .bool(false),
            ]),
            strict: true
        )

        let grammar = try engine.resolvedGrammarString(for: format)

        XCTAssertFalse(grammar?.isEmpty ?? true)
    }

    func testInferenceEngineDisablesGrammarWhenNonStrictSchemaCannotBeBridged() throws {
        let engine = InferenceEngine()
        let format = LLMResponseFormat(
            kind: .jsonSchema,
            schema: .object([
                "type": .string("object"),
                "properties": .string("oops"),
            ]),
            strict: false
        )

        let grammar = try engine.resolvedGrammarString(for: format)

        XCTAssertNil(grammar)
    }

    func testInferenceEngineUsesBridgeForGenericJSONObjectMode() throws {
        let engine = InferenceEngine()
        let format = LLMResponseFormat(kind: .json)

        let grammar = try engine.resolvedGrammarString(for: format)

        XCTAssertFalse(grammar?.isEmpty ?? true)
    }

    func testInferenceEngineRejectsInvalidStrictSchema() {
        let engine = InferenceEngine()
        let format = LLMResponseFormat(
            kind: .jsonSchema,
            schema: .object([
                "type": .string("object"),
                "properties": .string("oops"),
            ]),
            strict: true
        )

        XCTAssertThrowsError(try engine.resolvedGrammarString(for: format))
    }
}
