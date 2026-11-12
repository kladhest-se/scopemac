// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ScopeQueryTiming {
    double command_ms, request_ms, read_ms, total_ms;
    uint32_t read_calls, payload_bytes, wire_bytes;
    int link_speed, max_packet_bytes, overlapped;
} ScopeQueryTiming;
int scope_query_profiled(void *scope, const char *command, uint8_t *bytes, int capacity, ScopeQueryTiming *timing, char *error, int errorCapacity);
void *scope_open(char *error, int capacity);
int scope_write(void *scope, const char *command, char *error, int capacity);
int scope_query(void *scope, const char *command, uint8_t *bytes, int capacity, char *error, int errorCapacity);
void scope_set_overlap(void *scope, int enabled);
int scope_return_local(void *scope, char *error, int capacity);
void scope_close(void *scope);
#ifdef __cplusplus
}
#endif
