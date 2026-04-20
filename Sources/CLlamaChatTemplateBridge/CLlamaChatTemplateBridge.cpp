#include "CLlamaChatTemplateBridge.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <string>

// Pull in llama.cpp common chat infrastructure. The header lives in the
// vendored checkout (vendor/llama.cpp/common); the dylib exposes the symbols.
#include "common/chat.h"
#include "common/peg-parser.h"

#include <nlohmann/json.hpp>

namespace {

char * duplicate_c_string(const std::string & value) {
    auto * buffer = static_cast<char *>(std::malloc(value.size() + 1));
    if (buffer == nullptr) {
        return nullptr;
    }
    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

void set_out_error(char ** out_error, const std::string & message) {
    if (out_error != nullptr) {
        *out_error = duplicate_c_string(message);
    }
}

void null_out_params(char ** out_prompt,
                     char ** out_grammar,
                     char ** out_parser_blob,
                     int32_t * out_format,
                     bool * out_grammar_lazy,
                     char ** out_error) {
    if (out_prompt) { *out_prompt = nullptr; }
    if (out_grammar) { *out_grammar = nullptr; }
    if (out_parser_blob) { *out_parser_blob = nullptr; }
    if (out_format) { *out_format = 0; }
    if (out_grammar_lazy) { *out_grammar_lazy = false; }
    if (out_error) { *out_error = nullptr; }
}

}  // namespace

struct ankimate_chat_templates_handle {
    common_chat_templates_ptr templates;
};

extern "C" ankimate_chat_templates_handle *
ankimate_chat_templates_init(const void * model_ptr,
                             const char * chat_template_override,
                             char ** out_error) {
    if (out_error != nullptr) {
        *out_error = nullptr;
    }

    try {
        const auto * model = static_cast<const llama_model *>(model_ptr);
        std::string override_str = chat_template_override ? chat_template_override : "";
        auto tmpls = common_chat_templates_init(model, override_str);
        if (!tmpls) {
            set_out_error(out_error, "common_chat_templates_init returned null");
            return nullptr;
        }
        auto * handle = new ankimate_chat_templates_handle{std::move(tmpls)};
        return handle;
    } catch (const std::exception & error) {
        set_out_error(out_error, error.what());
        return nullptr;
    } catch (...) {
        set_out_error(out_error, "unknown error during chat_templates_init");
        return nullptr;
    }
}

extern "C" void ankimate_chat_templates_free(ankimate_chat_templates_handle * handle) {
    if (handle == nullptr) {
        return;
    }
    delete handle;
}

extern "C" bool ankimate_chat_apply(ankimate_chat_templates_handle * handle,
                                    const char * messages_json,
                                    const char * tools_json,
                                    const char * tool_choice,
                                    bool parallel_tool_calls,
                                    char ** out_prompt,
                                    char ** out_grammar,
                                    char ** out_parser_blob,
                                    int32_t * out_format,
                                    bool * out_grammar_lazy,
                                    char ** out_error) {
    null_out_params(out_prompt, out_grammar, out_parser_blob, out_format, out_grammar_lazy, out_error);

    if (handle == nullptr) {
        set_out_error(out_error, "handle must not be null");
        return false;
    }
    if (messages_json == nullptr) {
        set_out_error(out_error, "messages_json must not be null");
        return false;
    }

    try {
        common_chat_templates_inputs inputs;
        inputs.use_jinja = true;
        inputs.add_generation_prompt = true;
        inputs.parallel_tool_calls = parallel_tool_calls;

        auto messages_parsed = nlohmann::ordered_json::parse(messages_json);
        inputs.messages = common_chat_msgs_parse_oaicompat(messages_parsed);

        if (tools_json != nullptr && *tools_json != '\0') {
            auto tools_parsed = nlohmann::ordered_json::parse(tools_json);
            inputs.tools = common_chat_tools_parse_oaicompat(tools_parsed);
        }

        std::string tc = tool_choice ? tool_choice : "auto";
        inputs.tool_choice = common_chat_tool_choice_parse_oaicompat(tc);

        common_chat_params params = common_chat_templates_apply(handle->templates.get(), inputs);

        if (out_prompt) {
            *out_prompt = duplicate_c_string(params.prompt);
        }
        if (out_grammar) {
            *out_grammar = duplicate_c_string(params.grammar);
        }
        if (out_parser_blob) {
            *out_parser_blob = duplicate_c_string(params.parser);
        }
        if (out_format) {
            *out_format = static_cast<int32_t>(params.format);
        }
        if (out_grammar_lazy) {
            *out_grammar_lazy = params.grammar_lazy;
        }

        return true;
    } catch (const std::exception & error) {
        set_out_error(out_error, error.what());
        return false;
    } catch (...) {
        set_out_error(out_error, "unknown error during chat_apply");
        return false;
    }
}

extern "C" bool ankimate_chat_parse(int32_t format,
                                    const char * parser_blob,
                                    const char * input_text,
                                    bool is_partial,
                                    char ** out_result_json,
                                    char ** out_error) {
    if (out_result_json) { *out_result_json = nullptr; }
    if (out_error) { *out_error = nullptr; }

    if (input_text == nullptr) {
        set_out_error(out_error, "input_text must not be null");
        return false;
    }

    try {
        common_chat_parser_params parser_params;
        parser_params.format = static_cast<common_chat_format>(format);
        if (parser_blob != nullptr && *parser_blob != '\0') {
            parser_params.parser.load(std::string(parser_blob));
        }

        common_chat_msg msg = common_chat_parse(std::string(input_text), is_partial, parser_params);

        nlohmann::ordered_json result;
        result["role"] = msg.role.empty() ? std::string("assistant") : msg.role;
        result["content"] = msg.content;
        if (!msg.reasoning_content.empty()) {
            result["reasoning_content"] = msg.reasoning_content;
        }

        nlohmann::ordered_json calls = nlohmann::ordered_json::array();
        for (const auto & call : msg.tool_calls) {
            nlohmann::ordered_json entry;
            entry["id"] = call.id;
            entry["name"] = call.name;
            entry["arguments"] = call.arguments;
            calls.push_back(std::move(entry));
        }
        result["tool_calls"] = std::move(calls);

        if (out_result_json) {
            *out_result_json = duplicate_c_string(result.dump());
        }
        return true;
    } catch (const std::exception & error) {
        set_out_error(out_error, error.what());
        return false;
    } catch (...) {
        set_out_error(out_error, "unknown error during chat_parse");
        return false;
    }
}

extern "C" void ankimate_chat_bridge_free(void * pointer) {
    std::free(pointer);
}
