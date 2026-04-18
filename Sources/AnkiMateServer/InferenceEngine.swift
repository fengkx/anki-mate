// Inference engine — wraps llama.cpp C API for model loading and text generation.

import Foundation
import CllmLibrary
import AnkiMateRPC

enum InferenceError: Error, LocalizedError {
    case modelNotLoaded
    case loadFailed(String)
    case generationFailed(String)
    case contextAllocationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "No model is loaded"
        case .loadFailed(let msg): return "Failed to load model: \(msg)"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        case .contextAllocationFailed: return "Failed to allocate context"
        }
    }
}

final class InferenceEngine {
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

        // Create a fresh sampler chain for this generation
        if let s = sampler {
            llama_sampler_free(s)
        }
        let samplerChainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(samplerChainParams) else {
            throw InferenceError.generationFailed("Failed to create sampler chain")
        }

        // Add samplers: temperature -> top-k -> top-p -> dist/greedy
        if temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        }
        sampler = chain

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
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        }
        sampler = chain

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
}
