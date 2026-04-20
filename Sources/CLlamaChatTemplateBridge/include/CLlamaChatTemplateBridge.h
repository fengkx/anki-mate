#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle wrapping common_chat_templates + cached data derived from a loaded llama model.
typedef struct ankimate_chat_templates_handle ankimate_chat_templates_handle;

// Initialize chat templates from a loaded llama_model pointer.
// `model_ptr` is treated as a `const llama_model *`. `chat_template_override` may be NULL/empty
// to use the template embedded in the model.
// Returns NULL on failure; optionally writes an error string into *out_error (caller must free).
ankimate_chat_templates_handle *
ankimate_chat_templates_init(const void * model_ptr,
                             const char * chat_template_override,
                             char ** out_error);

void ankimate_chat_templates_free(ankimate_chat_templates_handle * handle);

// Apply the chat template to the given messages + tools.
//
// `messages_json` is a JSON array of OpenAI-style messages, e.g.
//   [{"role":"user","content":"hi"}]
// `tools_json` may be NULL or a JSON array of OpenAI-style tool definitions:
//   [{"type":"function","function":{"name":"foo","description":"...","parameters":{...}}}]
// `tool_choice` must be one of "auto"/"none"/"required" (case-insensitive) or NULL for auto.
//
// On success writes (malloc-owned, caller must free via ankimate_chat_bridge_free):
//   *out_prompt        — the final prompt string to feed the model
//   *out_grammar       — grammar string (possibly empty); caller should pass as root="root"
//   *out_parser_blob   — opaque parser blob (from common_peg_arena::save())
//   *out_format        — integer encoding of common_chat_format
//   *out_grammar_lazy  — whether grammar should be applied lazily (info only)
// Returns true on success, false on failure (error string written to *out_error).
bool ankimate_chat_apply(ankimate_chat_templates_handle * handle,
                         const char * messages_json,
                         const char * tools_json,
                         const char * tool_choice,
                         bool parallel_tool_calls,
                         char ** out_prompt,
                         char ** out_grammar,
                         char ** out_parser_blob,
                         int32_t * out_format,
                         bool * out_grammar_lazy,
                         char ** out_error);

// Parse model output text into an OpenAI-style `{content, tool_calls}` JSON blob.
// `parser_blob` must be the value returned from `ankimate_chat_apply` (or NULL/empty for content-only).
// `format` must be the value returned from `ankimate_chat_apply`.
// Writes to `*out_result_json`:
//   {
//     "content": "...",
//     "reasoning_content": "...",
//     "tool_calls": [ { "id": "...", "name": "...", "arguments": "<json-string>" } ]
//   }
// Returns true on success; on failure writes an error string into *out_error.
bool ankimate_chat_parse(int32_t format,
                         const char * parser_blob,
                         const char * input_text,
                         bool is_partial,
                         char ** out_result_json,
                         char ** out_error);

// Free any string buffer allocated by this bridge (via malloc).
void ankimate_chat_bridge_free(void * pointer);

#ifdef __cplusplus
}
#endif
