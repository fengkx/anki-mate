#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool ankimateserver_json_schema_to_grammar(
    const char * schema_json,
    bool force_gbnf,
    char ** out_grammar,
    char ** out_error
);

bool ankimateserver_json_schema_bridge_force_gbnf_default(void);

void ankimateserver_json_schema_bridge_free(void * pointer);

#ifdef __cplusplus
}
#endif
