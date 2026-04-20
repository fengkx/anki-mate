// Unified inference path — every call from `generate(...)` / `generateStreaming(...)`
// eventually goes through here. Prompt construction, grammar resolution, and
// output parsing are all delegated to the vendored llama.cpp chat template
// bridge, so tool calls, structured outputs, and plain chat completions share
// the same plumbing.
//
// The single public contract at the engine level is `generate(...) -> GenerateResult`,
// matching OpenAI's design where `tools` is merely an optional parameter.
// `generateStreaming(...)` piggy-backs onto the same run loop by passing a
// `tokenCallback` that fires on each produced piece.

import Foundation
import CllmLibrary
import CLlamaChatTemplateBridge
import AnkiMateRPC

extension InferenceEngine {
    /// The single source of truth for generating from a loaded model.
    ///
    /// - When `tools` is empty, the bridge still returns a valid model-specific
    ///   chat prompt (`COMMON_CHAT_FORMAT_CONTENT_ONLY`) with an empty grammar,
    ///   so this path handles plain chat completions just fine.
    /// - When `responseFormat` is supplied, its grammar takes precedence over
    ///   any grammar emitted by the chat template (so structured-output callers
    ///   keep their exact JSON-schema contract).
    /// - When `tokenCallback` is non-nil, each produced text piece is streamed
    ///   to the caller as it is decoded; tool-call parsing still runs on the
    ///   complete output at the end.
    func runGeneration(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        toolChoice: String?,
        parallelToolCalls: Bool,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float,
        tokenCallback: ((String) -> Void)? = nil
    ) throws -> GenerateResult {
        guard let model = self.modelPointer, let context = self.contextPointer else {
            throw InferenceError.modelNotLoaded
        }

        let startTime = DispatchTime.now()

        // 1. Resolve the chat templates handle. Must succeed (loadModel guarantees
        //    this), but defend against the model being unloaded concurrently.
        let templatesHandle = try ensureChatTemplatesHandle(for: model)

        // 2. Serialize messages + tools to JSON and apply the chat template.
        let messagesJSON = try Self.encodeMessagesForChat(messages)
        let toolsJSON = try Self.encodeToolsForChat(tools)
        let resolvedToolChoice = Self.normalizedToolChoice(toolChoice)

        let applied = try Self.applyChatTemplate(
            handle: templatesHandle,
            messagesJSON: messagesJSON,
            toolsJSON: toolsJSON,
            toolChoice: resolvedToolChoice,
            parallelToolCalls: parallelToolCalls
        )

        // 3. Grammar: responseFormat takes precedence (keeps structured output
        //    contracts intact); otherwise use whatever the template emits (tool
        //    grammar when tools are present, empty string otherwise).
        let responseFormatGrammar = try responseFormat.flatMap { format in
            try resolvedGrammarString(for: format)
        }
        if responseFormatGrammar != nil, !tools.isEmpty {
            throw InferenceError.unsupportedResponseFormat(
                "responseFormat cannot be combined with tool_calls in the chat-template bridge path"
            )
        }
        let resolvedGrammar = responseFormatGrammar ?? applied.grammarOrNil

        // 4. Tokenize prompt.
        let fullPrompt = applied.prompt
        let promptCStr = fullPrompt.cString(using: .utf8)!
        let vocab = llama_model_get_vocab(model)
        let maxTokenCount = Int32(fullPrompt.utf8.count + 128)
        var tokens = [llama_token](repeating: 0, count: Int(maxTokenCount))
        let nTokens = llama_tokenize(vocab, promptCStr, Int32(promptCStr.count - 1), &tokens, maxTokenCount, true, true)
        guard nTokens >= 0 else {
            throw InferenceError.generationFailed("Tokenization failed")
        }
        tokens = Array(tokens.prefix(Int(nTokens)))

        // 5. Reset KV cache and build a sampler with the resolved grammar.
        llama_memory_clear(llama_get_memory(context), true)

        let chain = try makeSamplerWithGrammar(
            model: model,
            grammarString: resolvedGrammar,
            temperature: temperature
        )

        // 6. Prompt decode.
        var batch = llama_batch_get_one(&tokens, Int32(tokens.count))
        var decodeResult = llama_decode(context, batch)
        guard decodeResult == 0 else {
            throw InferenceError.generationFailed("llama_decode failed on prompt (code: \(decodeResult))")
        }

        // 7. Generation loop.
        var outputTokens: [llama_token] = []
        var outputText = ""
        var finishReason: String?
        let eosToken = llama_vocab_eos(vocab)
        let eotToken = llama_vocab_eot(vocab)

        for _ in 0..<maxTokens {
            let newToken = try sampleNextTokenInternal(
                using: chain,
                grammarSampler: self.grammarSamplerPointer,
                context: context,
                model: model
            )
            acceptSampledTokenInternal(newToken, chain: chain, grammarSampler: self.grammarSamplerPointer)

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
                tokenCallback?(piece)
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

        // 8. Parse the output through the chat bridge. For content-only format
        //    (tools empty) this returns the raw text as content with no tool
        //    calls, which is exactly what plain chat completions want.
        let parsed = try Self.finalizeGeneratedOutput(
            text: outputText,
            format: applied.format,
            parserBlob: applied.parserBlob,
            usedResponseFormatGrammar: responseFormatGrammar != nil
        )

        let endTime = DispatchTime.now()
        let durationMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

        let trimmedContent = parsed.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls: [LLMToolCall]? = parsed.toolCalls.isEmpty ? nil : parsed.toolCalls

        return GenerateResult(
            text: trimmedContent,
            tokensUsed: outputTokens.count,
            durationMs: durationMs,
            finishReason: finishReason,
            toolCalls: toolCalls
        )
    }

    // MARK: - Sampler (grammar-aware, no LLMResponseFormat detour)

    private func makeSamplerWithGrammar(
        model: OpaquePointer,
        grammarString: String?,
        temperature: Float
    ) throws -> UnsafeMutablePointer<llama_sampler> {
        freeExistingSamplers()

        let samplerChainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(samplerChainParams) else {
            throw InferenceError.generationFailed("Failed to create sampler chain")
        }

        if temperature > 0 {
            llama_sampler_chain_add(
                chain,
                llama_sampler_init_penalties(64, 1.0, 0.0, 0.0)
            )
            llama_sampler_chain_add(chain, llama_sampler_init_top_n_sigma(-1.0))
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(chain, llama_sampler_init_typical(1.0, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(0.05, 1))
            llama_sampler_chain_add(
                chain,
                llama_sampler_init_temp_ext(temperature, 0.0, 1.0)
            )
        }

        if let grammar = grammarString, !grammar.isEmpty {
            let vocab = llama_model_get_vocab(model)
            guard let grammarSampler = grammar.withCString({ grammarCString in
                llama_sampler_init_grammar(vocab, grammarCString, "root")
            }) else {
                llama_sampler_free(chain)
                throw InferenceError.generationFailed("Failed to initialize grammar sampler for tool-call path")
            }
            setGrammarSampler(grammarSampler)
        }

        if temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_dist(InferenceEngine.defaultSamplingSeed))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        }

        setSampler(chain)
        return chain
    }

    // MARK: - Helpers for chat template bridge

    private struct AppliedChatTemplate {
        let prompt: String
        let grammar: String
        let parserBlob: String
        let format: Int32
        let grammarLazy: Bool

        var grammarOrNil: String? {
            grammar.isEmpty ? nil : grammar
        }
    }

    static func makeChatTemplatesHandle(for model: OpaquePointer) throws -> OpaquePointer {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rawModel = UnsafeRawPointer(model)
        guard let handlePointer = ankimate_chat_templates_init(rawModel, nil, &errorPointer) else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown bridge error"
            if let errorPointer { ankimate_chat_bridge_free(errorPointer) }
            throw InferenceError.generationFailed("chat_templates_init failed: \(message)")
        }
        if let errorPointer { ankimate_chat_bridge_free(errorPointer) }
        return handlePointer
    }

    private func ensureChatTemplatesHandle(for model: OpaquePointer) throws -> OpaquePointer {
        if let handle = chatTemplatesHandle {
            return handle
        }
        let handle = try Self.makeChatTemplatesHandle(for: model)
        chatTemplatesHandle = handle
        return handle
    }

    private static func applyChatTemplate(
        handle: OpaquePointer,
        messagesJSON: String,
        toolsJSON: String,
        toolChoice: String,
        parallelToolCalls: Bool
    ) throws -> AppliedChatTemplate {
        var promptPtr: UnsafeMutablePointer<CChar>?
        var grammarPtr: UnsafeMutablePointer<CChar>?
        var parserPtr: UnsafeMutablePointer<CChar>?
        var errorPtr: UnsafeMutablePointer<CChar>?
        var format: Int32 = 0
        var grammarLazy: Bool = false

        defer {
            [promptPtr, grammarPtr, parserPtr, errorPtr].forEach { pointer in
                if let pointer { ankimate_chat_bridge_free(pointer) }
            }
        }

        let ok = messagesJSON.withCString { messagesCString in
            toolsJSON.withCString { toolsCString in
                toolChoice.withCString { tcCString in
                    ankimate_chat_apply(
                        handle,
                        messagesCString,
                        toolsCString,
                        tcCString,
                        parallelToolCalls,
                        &promptPtr,
                        &grammarPtr,
                        &parserPtr,
                        &format,
                        &grammarLazy,
                        &errorPtr
                    )
                }
            }
        }

        guard ok else {
            let message = errorPtr.map { String(cString: $0) } ?? "unknown chat_apply error"
            throw InferenceError.generationFailed("chat_apply failed: \(message)")
        }

        let prompt = promptPtr.map { String(cString: $0) } ?? ""
        let grammar = grammarPtr.map { String(cString: $0) } ?? ""
        let parserBlob = parserPtr.map { String(cString: $0) } ?? ""

        return AppliedChatTemplate(
            prompt: prompt,
            grammar: grammar,
            parserBlob: parserBlob,
            format: format,
            grammarLazy: grammarLazy
        )
    }

    struct ParsedChatOutput {
        let content: String
        let toolCalls: [LLMToolCall]
    }

    static func finalizeGeneratedOutput(
        text: String,
        format: Int32,
        parserBlob: String,
        usedResponseFormatGrammar: Bool
    ) throws -> ParsedChatOutput {
        // When a structured-output responseFormat injects its own grammar, the
        // model emits raw JSON content rather than a template-specific assistant
        // envelope. In that mode the template parser is no longer applicable.
        if usedResponseFormatGrammar {
            return ParsedChatOutput(content: text, toolCalls: [])
        }

        return try parseChatOutput(
            format: format,
            parserBlob: parserBlob,
            text: text,
            isPartial: false
        )
    }

    static func parseChatOutput(
        format: Int32,
        parserBlob: String,
        text: String,
        isPartial: Bool
    ) throws -> ParsedChatOutput {
        var resultPtr: UnsafeMutablePointer<CChar>?
        var errorPtr: UnsafeMutablePointer<CChar>?
        defer {
            if let resultPtr { ankimate_chat_bridge_free(resultPtr) }
            if let errorPtr { ankimate_chat_bridge_free(errorPtr) }
        }

        let ok = parserBlob.withCString { parserCString in
            text.withCString { textCString in
                ankimate_chat_parse(format, parserCString, textCString, isPartial, &resultPtr, &errorPtr)
            }
        }

        guard ok, let resultPtr else {
            let message = errorPtr.map { String(cString: $0) } ?? "unknown chat_parse error"
            throw InferenceError.generationFailed("chat_parse failed: \(message)")
        }

        let resultString = String(cString: resultPtr)
        return try decodeParsedChatOutput(resultString)
    }

    private static func decodeParsedChatOutput(_ jsonString: String) throws -> ParsedChatOutput {
        guard let data = jsonString.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InferenceError.generationFailed("chat_parse returned invalid JSON")
        }

        let content = (raw["content"] as? String) ?? ""

        let calls = (raw["tool_calls"] as? [[String: Any]]) ?? []
        var parsedCalls: [LLMToolCall] = []
        parsedCalls.reserveCapacity(calls.count)

        for entry in calls {
            let name = (entry["name"] as? String) ?? ""
            guard !name.isEmpty else { continue }
            let id = (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let argumentsRaw = (entry["arguments"] as? String) ?? ""
            let arguments = decodeToolCallArguments(argumentsRaw)
            parsedCalls.append(LLMToolCall(id: id, name: name, arguments: arguments))
        }

        return ParsedChatOutput(content: content, toolCalls: parsedCalls)
    }

    private static func decodeToolCallArguments(_ raw: String) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            return .object([:])
        }
        if let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return decoded
        }
        // Tool call arguments should always be JSON; if parsing fails, fall back to
        // the raw string so callers can recover something.
        return .string(trimmed)
    }

    static func synthesizeMessages(systemPrompt: String?, prompt: String) -> [LLMMessage] {
        var result: [LLMMessage] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            result.append(LLMMessage(role: .system, content: systemPrompt))
        }
        result.append(LLMMessage(role: .user, content: prompt))
        return result
    }

    private static func encodeMessagesForChat(_ messages: [LLMMessage]) throws -> String {
        let array = messages.map { message -> [String: Any] in
            [
                "role": message.role.rawValue,
                "content": message.content,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: array, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeToolsForChat(_ tools: [LLMToolDefinition]) throws -> String {
        guard !tools.isEmpty else { return "" }
        let array = tools.map { tool -> [String: Any] in
            var fn: [String: Any] = ["name": tool.name]
            if let description = tool.description {
                fn["description"] = description
            }
            if let parameters = tool.parameters,
               let parametersJSON = try? JSONEncoder().encode(parameters),
               let parametersObject = try? JSONSerialization.jsonObject(with: parametersJSON) {
                fn["parameters"] = parametersObject
            } else {
                fn["parameters"] = ["type": "object"]
            }
            return [
                "type": "function",
                "function": fn,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: array, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalizedToolChoice(_ raw: String?) -> String {
        guard let raw else { return "auto" }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowered {
        case "auto", "none", "required":
            return lowered
        case "":
            return "auto"
        default:
            // Specific function choice (e.g. {"type":"function","function":{"name":"foo"}})
            // is not yet supported end-to-end; default to auto to keep templates happy.
            return "auto"
        }
    }
}
