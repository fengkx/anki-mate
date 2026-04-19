#include "CLlamaJSONSchemaBridge.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

std::string string_join(const std::vector<std::string> & values, const std::string & separator) {
    if (values.empty()) {
        return "";
    }

    std::string result = values.front();
    for (size_t index = 1; index < values.size(); ++index) {
        result += separator;
        result += values[index];
    }
    return result;
}

std::vector<std::string> string_split(const std::string & str, const std::string & delimiter) {
    if (delimiter.empty()) {
        return {str};
    }

    std::vector<std::string> parts;
    size_t start = 0;
    size_t end = str.find(delimiter);
    while (end != std::string::npos) {
        parts.push_back(str.substr(start, end - start));
        start = end + delimiter.length();
        end = str.find(delimiter, start);
    }
    parts.push_back(str.substr(start));
    return parts;
}

std::string string_repeat(const std::string & str, size_t n) {
    std::string result;
    result.reserve(str.size() * n);
    for (size_t index = 0; index < n; ++index) {
        result += str;
    }
    return result;
}

#include "../../vendor/llama.cpp/common/json-schema-to-grammar.cpp"

static char * duplicate_c_string(const std::string & value) {
    auto * buffer = static_cast<char *>(std::malloc(value.size() + 1));
    if (buffer == nullptr) {
        return nullptr;
    }
    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

bool ankimateserver_json_schema_to_grammar(
    const char * schema_json,
    bool force_gbnf,
    char ** out_grammar,
    char ** out_error
) {
    if (out_grammar != nullptr) {
        *out_grammar = nullptr;
    }
    if (out_error != nullptr) {
        *out_error = nullptr;
    }

    if (schema_json == nullptr) {
        if (out_error != nullptr) {
            *out_error = duplicate_c_string("schema_json must not be null");
        }
        return false;
    }

    try {
        auto schema = nlohmann::ordered_json::parse(schema_json);
        auto grammar = json_schema_to_grammar(schema, force_gbnf);
        if (out_grammar != nullptr) {
            *out_grammar = duplicate_c_string(grammar);
        }
        return out_grammar == nullptr || *out_grammar != nullptr;
    } catch (const std::exception & error) {
        if (out_error != nullptr) {
            *out_error = duplicate_c_string(error.what());
        }
        return false;
    }
}

bool ankimateserver_json_schema_bridge_force_gbnf_default(void) {
#ifdef LLAMA_USE_LLGUIDANCE
    return false;
#else
    return true;
#endif
}

void ankimateserver_json_schema_bridge_free(void * pointer) {
    std::free(pointer);
}
