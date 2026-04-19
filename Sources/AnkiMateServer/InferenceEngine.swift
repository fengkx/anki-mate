// Inference engine — wraps llama.cpp C API for model loading and text generation.

import Foundation
import CllmLibrary
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
    private var model: OpaquePointer? // llama_model *
    private var context: OpaquePointer? // llama_context *
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private(set) var loadedModelPath: String?

    var isModelLoaded: Bool {
        model != nil && context != nil
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
        ctxParams.n_threads = Int32(max(ProcessInfo.processInfo.activeProcessorCount - 2, 1))

        guard let newCtx = llama_init_from_model(newModel, ctxParams) else {
            llama_model_free(newModel)
            throw InferenceError.contextAllocationFailed
        }

        model = newModel
        context = newCtx
        sampler = nil
        loadedModelPath = path

        fputs("Model loaded successfully (ctx=\(contextSize), gpu_layers=\(gpuLayers))\n", stderr)
    }

    func unloadModel() {
        if let s = sampler {
            llama_sampler_free(s)
            sampler = nil
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

    func generate(
        prompt: String,
        systemPrompt: String?,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float
    ) throws -> GenerateResult {
        guard let model = model, let context = context else {
            throw InferenceError.modelNotLoaded
        }

        let startTime = DispatchTime.now()

        // Build the full prompt with chat template
        let fullPrompt: String
        if let sys = systemPrompt, !sys.isEmpty {
            fullPrompt = "<start_of_turn>user\n\(sys)\n\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
        } else {
            fullPrompt = "<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
        }

        // Tokenize
        let promptCStr = fullPrompt.cString(using: .utf8)!
        let vocab = llama_model_get_vocab(model)
        let maxTokenCount = Int32(fullPrompt.utf8.count + 128)
        var tokens = [llama_token](repeating: 0, count: Int(maxTokenCount))
        let nTokens = llama_tokenize(vocab, promptCStr, Int32(promptCStr.count - 1), &tokens, maxTokenCount, true, true)

        guard nTokens >= 0 else {
            throw InferenceError.generationFailed("Tokenization failed")
        }

        tokens = Array(tokens.prefix(Int(nTokens)))

        // Clear KV cache
        llama_memory_clear(llama_get_memory(context), true)

        sampler = try makeSampler(
            model: model,
            responseFormat: responseFormat,
            temperature: temperature
        )
        guard let chain = sampler else {
            throw InferenceError.generationFailed("Failed to create sampler chain")
        }

        // Process prompt tokens in a batch
        var batch = llama_batch_get_one(&tokens, Int32(tokens.count))
        var decodeResult = llama_decode(context, batch)
        guard decodeResult == 0 else {
            throw InferenceError.generationFailed("llama_decode failed on prompt (code: \(decodeResult))")
        }

        // Generate tokens one by one
        var outputTokens: [llama_token] = []
        var streamedText = ""
        var finishReason: String?
        let eosToken = llama_vocab_eos(vocab)
        let eotToken = llama_vocab_eot(vocab)

        for _ in 0..<maxTokens {
            let newToken = llama_sampler_sample(chain, context, -1)

            // Check for end of generation
            if newToken == eosToken || newToken == eotToken {
                finishReason = "stop"
                break
            }
            if llama_vocab_is_eog(vocab, newToken) {
                finishReason = "stop"
                break
            }

            outputTokens.append(newToken)

            var buf = [CChar](repeating: 0, count: 256)
            let len = llama_token_to_piece(vocab, newToken, &buf, 256, 0, true)
            if len > 0 {
                buf[Int(len)] = 0
                streamedText += String(cString: buf)
            }

            // Prepare next token for decoding
            var singleToken = [newToken]
            batch = llama_batch_get_one(&singleToken, 1)
            decodeResult = llama_decode(context, batch)
            if decodeResult != 0 {
                fputs("Warning: llama_decode returned \(decodeResult) during generation\n", stderr)
                finishReason = "error"
                break
            }
        }

        if finishReason == nil, outputTokens.count >= maxTokens {
            finishReason = "length"
        }

        let endTime = DispatchTime.now()
        let durationMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

        return GenerateResult(
            text: streamedText.trimmingCharacters(in: .whitespacesAndNewlines),
            tokensUsed: outputTokens.count,
            durationMs: durationMs,
            finishReason: finishReason
        )
    }

    func generateStreaming(
        prompt: String,
        systemPrompt: String?,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float,
        onToken: (String) -> Void
    ) throws -> GenerateResult {
        guard let model = model, let context = context else {
            throw InferenceError.modelNotLoaded
        }

        let startTime = DispatchTime.now()
        let fullPrompt: String
        if let sys = systemPrompt, !sys.isEmpty {
            fullPrompt = "<start_of_turn>user\n\(sys)\n\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
        } else {
            fullPrompt = "<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
        }

        let promptCStr = fullPrompt.cString(using: .utf8)!
        let vocab = llama_model_get_vocab(model)
        let maxTokenCount = Int32(fullPrompt.utf8.count + 128)
        var tokens = [llama_token](repeating: 0, count: Int(maxTokenCount))
        let nTokens = llama_tokenize(vocab, promptCStr, Int32(promptCStr.count - 1), &tokens, maxTokenCount, true, true)
        guard nTokens >= 0 else {
            throw InferenceError.generationFailed("Tokenization failed")
        }
        tokens = Array(tokens.prefix(Int(nTokens)))

        llama_memory_clear(llama_get_memory(context), true)

        sampler = try makeSampler(
            model: model,
            responseFormat: responseFormat,
            temperature: temperature
        )
        guard let chain = sampler else {
            throw InferenceError.generationFailed("Failed to create sampler chain")
        }

        var batch = llama_batch_get_one(&tokens, Int32(tokens.count))
        var decodeResult = llama_decode(context, batch)
        guard decodeResult == 0 else {
            throw InferenceError.generationFailed("llama_decode failed on prompt (code: \(decodeResult))")
        }

        var outputTokens: [llama_token] = []
        var outputText = ""
        var finishReason: String?
        let eosToken = llama_vocab_eos(vocab)
        let eotToken = llama_vocab_eot(vocab)

        for _ in 0..<maxTokens {
            let newToken = llama_sampler_sample(chain, context, -1)
            if newToken == eosToken || newToken == eotToken || llama_vocab_is_eog(vocab, newToken) {
                finishReason = "stop"
                break
            }

            outputTokens.append(newToken)

            var buf = [CChar](repeating: 0, count: 256)
            let len = llama_token_to_piece(vocab, newToken, &buf, 256, 0, true)
            if len > 0 {
                buf[Int(len)] = 0
                let piece = String(cString: buf)
                outputText += piece
                onToken(piece)
            }

            var singleToken = [newToken]
            batch = llama_batch_get_one(&singleToken, 1)
            decodeResult = llama_decode(context, batch)
            if decodeResult != 0 {
                fputs("Warning: llama_decode returned \(decodeResult) during generation\n", stderr)
                finishReason = "error"
                break
            }
        }

        if finishReason == nil, outputTokens.count >= maxTokens {
            finishReason = "length"
        }

        let endTime = DispatchTime.now()
        let durationMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
        return GenerateResult(
            text: outputText.trimmingCharacters(in: .whitespacesAndNewlines),
            tokensUsed: outputTokens.count,
            durationMs: durationMs,
            finishReason: finishReason
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
        let samplerChainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(samplerChainParams) else {
            throw InferenceError.generationFailed("Failed to create sampler chain")
        }

        if temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        }

        if let grammar = try grammarSampler(for: responseFormat, model: model) {
            llama_sampler_chain_add(chain, grammar)
        }

        if temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        }
        return chain
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
            return Self.genericJSONGrammar
        case .jsonSchema:
            guard let schema = responseFormat.schema else {
                if responseFormat.strict == true {
                    throw InferenceError.unsupportedResponseFormat("json_schema requires schema when strict=true")
                }
                fputs("Warning: json_schema requested without schema; falling back to generic JSON grammar\n", stderr)
                return Self.genericJSONGrammar
            }
            do {
                return try JSONSchemaGrammarCompiler().compileRootGrammar(from: schema)
            } catch let error as JSONSchemaGrammarCompilerError {
                if responseFormat.strict == true {
                    throw InferenceError.unsupportedResponseFormat(error.localizedDescription)
                }
                fputs("Warning: \(error.localizedDescription). Falling back to generic JSON grammar\n", stderr)
                return Self.genericJSONGrammar
            } catch {
                throw error
            }
        }
    }

    static let genericJSONGrammar = """
    root ::= ws value ws
    value ::= object | array | string | number | boolean | null
    object ::= "{" ws "}" | "{" ws members ws "}"
    members ::= pair | pair ws "," ws members
    pair ::= string ws ":" ws value
    array ::= "[" ws "]" | "[" ws elements ws "]"
    elements ::= value | value ws "," ws elements
    string ::= "\"" char* "\""
    char ::= [^"\\\\\\x00-\\x1F] | "\\" (["\\\\/bfnrt] | "u" hex hex hex hex)
    hex ::= [0-9a-fA-F]
    number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)?
    boolean ::= "true" | "false"
    null ::= "null"
    ws ::= [ \\t\\n\\r]*
    """
}
