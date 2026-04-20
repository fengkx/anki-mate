// Inference engine — wraps llama.cpp C API for model loading and text generation.

import Foundation
import CllmLibrary
import CLlamaJSONSchemaBridge
import CLlamaChatTemplateBridge
import AnkiMateRPC

enum InferenceError: Error, LocalizedError {
    case modelNotLoaded
    case loadFailed(String)
    case generationFailed(String)
    case contextAllocationFailed
    case unsupportedResponseFormat(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "No model is loaded"
        case .loadFailed(let msg): return "Failed to load model: \(msg)"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        case .contextAllocationFailed: return "Failed to allocate context"
        case .unsupportedResponseFormat(let msg): return "Unsupported response format: \(msg)"
        }
    }
}

final class InferenceEngine: InferenceServing {
    private enum ThreadingDefaults {
        static let generationThreadsEnvironmentKey = "DICTKIT_LLM_THREADS"
        static let batchThreadsEnvironmentKey = "DICTKIT_LLM_THREADS_BATCH"
    }

    struct SamplerPlan: Equatable {
        let seed: UInt32
        let stageNames: [String]
    }

    private enum SamplingDefaults {
        static let seed = UInt32(LLAMA_DEFAULT_SEED)
        static let topK: Int32 = 40
        static let topP: Float = 0.95
        static let minKeep: Int = 1
        static let minP: Float = 0.05
        static let typicalP: Float = 1.0
        static let topNSigma: Float = -1.0
        static let xtcProbability: Float = 0.0
        static let xtcThreshold: Float = 0.1
        static let dynamicTemperatureRange: Float = 0.0
        static let dynamicTemperatureExponent: Float = 1.0
        static let penaltyLastN: Int32 = 64
        static let penaltyRepeat: Float = 1.0
        static let penaltyFrequency: Float = 0.0
        static let penaltyPresence: Float = 0.0
        static let dryMultiplier: Float = 0.0
        static let dryBase: Float = 1.75
        static let dryAllowedLength: Int32 = 2
        static let dryPenaltyLastN: Int32 = -1
        static let drySequenceBreakers = ["\n", ":", "\"", "*"]
    }

    private var model: OpaquePointer? // llama_model *
    private var context: OpaquePointer? // llama_context *
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var grammarSampler: UnsafeMutablePointer<llama_sampler>?
    private(set) var loadedModelPath: String?
    /// Opaque handle to the `CLlamaChatTemplateBridge` chat templates. Eagerly created per loaded model.
    var chatTemplatesHandle: OpaquePointer?

    var isModelLoaded: Bool {
        model != nil && context != nil
    }

    // Exposed for the tool-calls extension (same module, same file is not required).
    var modelPointer: OpaquePointer? { model }
    var contextPointer: OpaquePointer? { context }
    var samplerPointer: UnsafeMutablePointer<llama_sampler>? { sampler }
    var grammarSamplerPointer: UnsafeMutablePointer<llama_sampler>? { grammarSampler }

    func setSampler(_ newSampler: UnsafeMutablePointer<llama_sampler>?) {
        self.sampler = newSampler
    }

    func setGrammarSampler(_ newSampler: UnsafeMutablePointer<llama_sampler>?) {
        self.grammarSampler = newSampler
    }

    func freeExistingSamplers() {
        if let s = sampler {
            llama_sampler_free(s)
            sampler = nil
        }
        if let grammarSampler {
            llama_sampler_free(grammarSampler)
            self.grammarSampler = nil
        }
    }

    init() {
        llama_backend_init()
        fputs("llama.cpp backend initialized\n", stderr)
    }

    deinit {
        unloadModel()
        llama_backend_free()
    }

    // MARK: - Model Loading

    func loadModel(path: String, contextSize: Int, gpuLayers: Int) throws {
        // Unload any existing model first
        unloadModel()

        fputs("Loading model: \(path)\n", stderr)

        // Model params
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Int32(gpuLayers)

        guard let newModel = llama_model_load_from_file(path, modelParams) else {
            throw InferenceError.loadFailed("llama_model_load_from_file returned nil")
        }

        // Context params
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextSize)
        ctxParams.n_batch = UInt32(min(contextSize, 2048))
        let threadSettings = Self.resolveThreadSettings(environment: ProcessInfo.processInfo.environment)
        ctxParams.n_threads = Int32(threadSettings.generationThreads)
        ctxParams.n_threads_batch = Int32(threadSettings.batchThreads)

        guard let newCtx = llama_init_from_model(newModel, ctxParams) else {
            llama_model_free(newModel)
            throw InferenceError.contextAllocationFailed
        }

        let newChatTemplatesHandle: OpaquePointer
        do {
            newChatTemplatesHandle = try Self.makeChatTemplatesHandle(for: newModel)
        } catch {
            llama_free(newCtx)
            llama_model_free(newModel)
            throw InferenceError.loadFailed("chat templates unavailable: \(error.localizedDescription)")
        }

        model = newModel
        context = newCtx
        sampler = nil
        grammarSampler = nil
        chatTemplatesHandle = newChatTemplatesHandle
        loadedModelPath = path

        llama_set_n_threads(newCtx, Int32(threadSettings.generationThreads), Int32(threadSettings.batchThreads))
        fputs(
            "Model loaded successfully (ctx=\(contextSize), gpu_layers=\(gpuLayers), n_threads=\(threadSettings.generationThreads), n_threads_batch=\(threadSettings.batchThreads))\n",
            stderr
        )
    }

    func unloadModel() {
        if let s = sampler {
            llama_sampler_free(s)
            sampler = nil
        }
        if let grammarSampler {
            llama_sampler_free(grammarSampler)
            self.grammarSampler = nil
        }
        if let chatTemplatesHandle {
            ankimate_chat_templates_free(chatTemplatesHandle)
            self.chatTemplatesHandle = nil
        }
        if context != nil {
            llama_free(context)
            context = nil
        }
        if model != nil {
            llama_model_free(model)
            model = nil
        }
        loadedModelPath = nil
    }

    // MARK: - Generation
    //
    // Both generate() and generateStreaming() are thin shells that delegate to
    // runGeneration() in the `+ToolCalls` extension. Prompt construction, grammar
    // selection, and output parsing are all done by the llama.cpp chat template
    // bridge — there is no hand-rolled Gemma template string anymore.

    func generate(
        prompt: String,
        systemPrompt: String?,
        messages: [LLMMessage]? = nil,
        tools: [LLMToolDefinition]? = nil,
        toolChoice: String? = nil,
        parallelToolCalls: Bool = false,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float
    ) throws -> GenerateResult {
        let effectiveMessages = messages
            ?? Self.synthesizeMessages(systemPrompt: systemPrompt, prompt: prompt)
        return try runGeneration(
            messages: effectiveMessages,
            tools: tools ?? [],
            toolChoice: toolChoice,
            parallelToolCalls: parallelToolCalls,
            responseFormat: responseFormat,
            maxTokens: maxTokens,
            temperature: temperature,
            tokenCallback: nil
        )
    }

    func generateStreaming(
        prompt: String,
        systemPrompt: String?,
        tools: [LLMToolDefinition]? = nil,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float,
        onToken: @escaping (String) -> Void
    ) throws -> GenerateResult {
        if let tools, !tools.isEmpty {
            // Tool-call parsing needs the full output in one shot; streaming
            // mode can't emit partial tool_calls reliably. Callers should use
            // generate() without streaming when they need tools.
            throw InferenceError.unsupportedResponseFormat(
                "streaming generation does not support tool_calls; call generate without streaming"
            )
        }
        let effectiveMessages = Self.synthesizeMessages(systemPrompt: systemPrompt, prompt: prompt)
        return try runGeneration(
            messages: effectiveMessages,
            tools: [],
            toolChoice: nil,
            parallelToolCalls: false,
            responseFormat: responseFormat,
            maxTokens: maxTokens,
            temperature: temperature,
            tokenCallback: onToken
        )
    }

    private func makeSampler(
        model: OpaquePointer,
        responseFormat: LLMResponseFormat?,
        temperature: Float
    ) throws -> UnsafeMutablePointer<llama_sampler>? {
        if let s = sampler {
            llama_sampler_free(s)
        }
        if let grammarSampler {
            llama_sampler_free(grammarSampler)
            self.grammarSampler = nil
        }
        let samplerChainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(samplerChainParams) else {
            throw InferenceError.generationFailed("Failed to create sampler chain")
        }

        if temperature > 0 {
            llama_sampler_chain_add(
                chain,
                llama_sampler_init_penalties(
                    SamplingDefaults.penaltyLastN,
                    SamplingDefaults.penaltyRepeat,
                    SamplingDefaults.penaltyFrequency,
                    SamplingDefaults.penaltyPresence
                )
            )
            llama_sampler_chain_add(chain, try makeDrySampler(model: model))
            llama_sampler_chain_add(chain, llama_sampler_init_top_n_sigma(SamplingDefaults.topNSigma))
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(SamplingDefaults.topK))
            llama_sampler_chain_add(chain, llama_sampler_init_typical(SamplingDefaults.typicalP, SamplingDefaults.minKeep))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(SamplingDefaults.topP, SamplingDefaults.minKeep))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(SamplingDefaults.minP, SamplingDefaults.minKeep))
            llama_sampler_chain_add(
                chain,
                llama_sampler_init_xtc(
                    SamplingDefaults.xtcProbability,
                    SamplingDefaults.xtcThreshold,
                    SamplingDefaults.minKeep,
                    Self.defaultSamplingSeed
                )
            )
            llama_sampler_chain_add(
                chain,
                llama_sampler_init_temp_ext(
                    temperature,
                    SamplingDefaults.dynamicTemperatureRange,
                    SamplingDefaults.dynamicTemperatureExponent
                )
            )
        }

        grammarSampler = try grammarSampler(for: responseFormat, model: model)

        if temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_dist(Self.defaultSamplingSeed))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        }
        return chain
    }

    private func makeDrySampler(model: OpaquePointer) throws -> UnsafeMutablePointer<llama_sampler> {
        let allocatedBreakers = SamplingDefaults.drySequenceBreakers.map { strdup($0) }
        defer {
            for pointer in allocatedBreakers {
                free(pointer)
            }
        }

        var breakerPointers = allocatedBreakers.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }

        return try breakerPointers.withUnsafeMutableBufferPointer { buffer in
            guard let sampler = llama_sampler_init_dry(
                llama_model_get_vocab(model),
                llama_model_n_ctx_train(model),
                SamplingDefaults.dryMultiplier,
                SamplingDefaults.dryBase,
                SamplingDefaults.dryAllowedLength,
                SamplingDefaults.dryPenaltyLastN,
                buffer.baseAddress,
                buffer.count
            ) else {
                throw InferenceError.generationFailed("Failed to initialize dry sampler")
            }
            return sampler
        }
    }

    private func acceptSampledToken(
        _ token: llama_token,
        chain: UnsafeMutablePointer<llama_sampler>,
        grammarSampler: UnsafeMutablePointer<llama_sampler>?
    ) {
        if let grammarSampler {
            llama_sampler_accept(grammarSampler, token)
        }
        llama_sampler_accept(chain, token)
    }

    func acceptSampledTokenInternal(
        _ token: llama_token,
        chain: UnsafeMutablePointer<llama_sampler>,
        grammarSampler: UnsafeMutablePointer<llama_sampler>?
    ) {
        acceptSampledToken(token, chain: chain, grammarSampler: grammarSampler)
    }

    private func sampleNextToken(
        using chain: UnsafeMutablePointer<llama_sampler>,
        grammarSampler: UnsafeMutablePointer<llama_sampler>?,
        context: OpaquePointer,
        model: OpaquePointer
    ) throws -> llama_token {
        llama_synchronize(context)
        guard let logits = llama_get_logits_ith(context, -1) else {
            throw InferenceError.generationFailed("Missing logits for sampling")
        }
        let vocabulary = llama_model_get_vocab(model)
        let vocabularySize = Int(llama_vocab_n_tokens(vocabulary))

        func sampleCandidate(applyGrammarFirst: Bool) throws -> llama_token {
            var candidates: [llama_token_data] = []
            candidates.reserveCapacity(vocabularySize)
            for tokenIndex in 0..<vocabularySize {
                candidates.append(
                    llama_token_data(
                        id: llama_token(tokenIndex),
                        logit: logits[tokenIndex],
                        p: 0
                    )
                )
            }

            return try candidates.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    throw InferenceError.generationFailed("Failed to build candidate buffer")
                }
                var candidateArray = llama_token_data_array(
                    data: baseAddress,
                    size: buffer.count,
                    selected: -1,
                    sorted: false
                )
                if applyGrammarFirst, let grammarSampler {
                    llama_sampler_apply(grammarSampler, &candidateArray)
                }
                llama_sampler_apply(chain, &candidateArray)
                guard candidateArray.selected >= 0 else {
                    throw InferenceError.generationFailed("No token selected during sampling")
                }
                return candidateArray.data[Int(candidateArray.selected)].id
            }
        }

        let sampledToken = try sampleCandidate(applyGrammarFirst: false)
        guard let grammarSampler else {
            return sampledToken
        }

        var singleTokenData = llama_token_data(id: sampledToken, logit: 1, p: 0)
        let isGrammarValid = withUnsafeMutablePointer(to: &singleTokenData) { tokenPointer in
            var singleTokenArray = llama_token_data_array(
                data: tokenPointer,
                size: 1,
                selected: -1,
                sorted: false
            )
            llama_sampler_apply(grammarSampler, &singleTokenArray)
            return singleTokenArray.data[0].logit != -Float.infinity
        }
        if isGrammarValid {
            return sampledToken
        }

        return try sampleCandidate(applyGrammarFirst: true)
    }

    func sampleNextTokenInternal(
        using chain: UnsafeMutablePointer<llama_sampler>,
        grammarSampler: UnsafeMutablePointer<llama_sampler>?,
        context: OpaquePointer,
        model: OpaquePointer
    ) throws -> llama_token {
        try sampleNextToken(using: chain, grammarSampler: grammarSampler, context: context, model: model)
    }

    private func grammarSampler(
        for responseFormat: LLMResponseFormat?,
        model: OpaquePointer
    ) throws -> UnsafeMutablePointer<llama_sampler>? {
        guard let responseFormat else {
            return nil
        }
        let grammar = try resolvedGrammarString(for: responseFormat)
        guard let grammar, grammar.isEmpty == false else {
            return nil
        }
        let vocab = llama_model_get_vocab(model)
        guard let sampler = grammar.withCString({ grammarCString in
            llama_sampler_init_grammar(vocab, grammarCString, "root")
        }) else {
            throw InferenceError.generationFailed("Failed to initialize grammar sampler")
        }
        return sampler
    }

    func resolvedGrammarString(for responseFormat: LLMResponseFormat) throws -> String? {
        switch responseFormat.kind {
        case .text:
            return nil
        case .json:
            do {
                return try Self.compileGrammarWithUpstreamBridge(from: Self.genericJSONObjectSchema)
            } catch {
                fputs("Warning: generic json bridge failed (\(error.localizedDescription)); disabling grammar constraint for json mode\n", stderr)
                return nil
            }
        case .jsonSchema:
            guard let schema = responseFormat.schema else {
                if responseFormat.strict == true {
                    throw InferenceError.unsupportedResponseFormat("json_schema requires schema when strict=true")
                }
                fputs("Warning: json_schema requested without schema; disabling grammar constraint\n", stderr)
                return nil
            }
            do {
                return try Self.compileGrammarWithUpstreamBridge(from: schema)
            } catch {
                if responseFormat.strict == true {
                    throw InferenceError.unsupportedResponseFormat(error.localizedDescription)
                }
                fputs("Warning: upstream json_schema bridge failed (\(error.localizedDescription)); disabling grammar constraint\n", stderr)
                return nil
            }
        }
    }

    static let genericJSONObjectSchema: JSONValue = .object([
        "type": .string("object")
    ])

    static let defaultSamplingSeed = SamplingDefaults.seed

    static func defaultSamplerPlan(for temperature: Float) -> SamplerPlan {
        if temperature > 0 {
            return SamplerPlan(
                seed: defaultSamplingSeed,
                stageNames: [
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

        return SamplerPlan(seed: defaultSamplingSeed, stageNames: ["greedy"])
    }

    struct ThreadSettings: Equatable {
        let generationThreads: Int
        let batchThreads: Int
    }

    static func resolveThreadSettings(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> ThreadSettings {
        let safeActiveProcessorCount = max(activeProcessorCount, 1)
        let defaultGenerationThreads = max(safeActiveProcessorCount - 2, 1)
        let defaultBatchThreads = max(safeActiveProcessorCount, 1)

        let generationThreads = parsePositiveThreadOverride(
            environment[ThreadingDefaults.generationThreadsEnvironmentKey]
        ) ?? defaultGenerationThreads
        let batchThreads = parsePositiveThreadOverride(
            environment[ThreadingDefaults.batchThreadsEnvironmentKey]
        ) ?? defaultBatchThreads

        return ThreadSettings(
            generationThreads: max(generationThreads, 1),
            batchThreads: max(batchThreads, 1)
        )
    }

    private static func parsePositiveThreadOverride(_ rawValue: String?) -> Int? {
        guard let rawValue,
              let parsed = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0 else {
            return nil
        }

        return parsed
    }

    private static func compileGrammarWithUpstreamBridge(from schema: JSONValue) throws -> String {
        let schemaJSON = try String(decoding: JSONEncoder().encode(schema), as: UTF8.self)
        var grammarPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        defer {
            if let grammarPointer {
                ankimateserver_json_schema_bridge_free(grammarPointer)
            }
            if let errorPointer {
                ankimateserver_json_schema_bridge_free(errorPointer)
            }
        }

        let didSucceed = schemaJSON.withCString { schemaCString in
            ankimateserver_json_schema_to_grammar(
                schemaCString,
                ankimateserver_json_schema_bridge_force_gbnf_default(),
                &grammarPointer,
                &errorPointer
            )
        }

        if didSucceed {
            guard let grammarPointer else {
                throw InferenceError.unsupportedResponseFormat("upstream json_schema bridge returned no grammar")
            }
            return String(cString: grammarPointer)
        }

        let message = errorPointer.map { String(cString: $0) } ?? "unknown bridge error"
        throw InferenceError.unsupportedResponseFormat(message)
    }
}
