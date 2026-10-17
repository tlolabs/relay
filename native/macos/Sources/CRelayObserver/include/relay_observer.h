#ifndef RELAY_OBSERVER_H
#define RELAY_OBSERVER_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Version 2. UTF-8 JSON input is borrowed for the duration of the call.
   All returned strings are owned by Rust and must be freed exactly once.
   A handle must not be destroyed while another call uses it. */
uint32_t relay_observer_api_version(void);
void *relay_observer_start(const char *config_json);
char *relay_observer_last_error(void);
char *relay_observer_snapshot(void *handle);
uint8_t relay_observer_notice(void *handle, const char *notice_json);
uint8_t relay_observer_iflicks_event(void *handle, const char *observation_json);
uint8_t relay_observer_marker(void *handle, const char *text);
char *relay_observer_stop(void *handle);
void relay_observer_destroy(void *handle);
void relay_observer_free_string(char *value);
#ifdef __cplusplus
}
#endif
#endif
