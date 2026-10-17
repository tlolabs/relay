#ifndef RELAY_CORE_H
#define RELAY_CORE_H
#include <stdint.h>
/* ABI 1. Inputs are borrowed UTF-8 JSON. Returned strings are Rust-owned.
   A handle serializes commands; close only after all callers have stopped. */
uint32_t relay_core_api_version(void);
void *relay_core_open(const char *database_path, char **error);
char *relay_core_command(void *handle, const char *request_json);
void relay_core_close(void *handle);
void relay_core_free_string(char *text);
#endif
