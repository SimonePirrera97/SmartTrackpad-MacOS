// Client side of wire protocol v2: handshake, heartbeats, liveness, app
// context. Swift counterpart: apps/Shared/ConnectionModel.swift (role .client).
#include "trackpad_core.h"
#include "cJSON.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const struct { const char *name; uint32_t bit; } capability_table[] = {
    { "pointer.move", 0 }, { "mouse.click", 0 }, { "mouse.button", 0 }, { "scroll.pixel", 0 },
    { "input.releaseAll", 0 }, { "scroll.stopMomentum", 0 },
    { "action.standard", TP_CAP_STANDARD_ACTIONS }, { "scroll.pixel.highRange", TP_CAP_HIGH_RANGE_SCROLL },
    { "gesture.magnify.experimental", TP_CAP_PINCH }, { "gesture.pages.experimental", TP_CAP_PAGES },
    { "gesture.missionControl.experimental", TP_CAP_MISSION_CONTROL },
    { "action.showDesktop.experimental", TP_CAP_SHOW_DESKTOP },
    { "action.appControls.v2", TP_CAP_APP_CONTROLS }, { "input.binary.v1", TP_CAP_BINARY },
};
#define CAPABILITY_COUNT (sizeof capability_table / sizeof capability_table[0])
#define BASIC_COUNT 6

static void notify(tp_session_t *s, const char *reason) {
    if (s->callbacks.changed) s->callbacks.changed(s->callbacks.context, reason);
}

static void reset(tp_session_t *s) {
    s->state = TP_SESSION_IDLE;
    s->sent = s->received = s->received_timestamp = 0;
    s->capabilities = 0; s->has_app = false;
    s->buffered = 0; s->binary_size = -1;
}

void tp_session_init(tp_session_t *s, tp_session_callbacks_t callbacks) {
    memset(s, 0, sizeof *s);
    s->callbacks = callbacks;
    reset(s);
}

void tp_session_stop(tp_session_t *s, const char *reason) {
    bool was_active = s->state != TP_SESSION_IDLE;
    reset(s);
    if (was_active) notify(s, reason ? reason : "Disconnected");
}

static bool write_json(tp_session_t *s, const char *type, const char *extra, uint64_t now_ms) {
    char line[1024];
    s->sent++;
    int length = snprintf(line, sizeof line,
        "{\"version\":2,\"session\":\"%s\",\"sequence\":%llu,\"timestampMilliseconds\":%llu,\"type\":\"%s\"%s}\n",
        s->session, (unsigned long long)s->sent, (unsigned long long)now_ms, type, extra ? extra : "");
    if (length <= 0 || (size_t)length >= sizeof line) return false;
    return s->callbacks.write((const uint8_t *)line, (size_t)length, s->callbacks.context);
}

void tp_session_start(tp_session_t *s, const char *uuid, const char *code, const char *proof, uint64_t now_ms) {
    reset(s);
    snprintf(s->session, sizeof s->session, "%s", uuid);
    s->direct = code == NULL;
    snprintf(s->code, sizeof s->code, "%s", code ? code : "");
    char extra[720];
    int used = 0;
    if (code) used += snprintf(extra + used, sizeof extra - used, ",\"code\":\"%s\"", code);
    if (code && proof) used += snprintf(extra + used, sizeof extra - used, ",\"boardProof\":\"%s\"", proof);
    used += snprintf(extra + used, sizeof extra - used, ",\"capabilities\":[");
    for (size_t i = 0; i < CAPABILITY_COUNT; i++) {
        used += snprintf(extra + used, sizeof extra - used, "%s\"%s\"", i ? "," : "", capability_table[i].name);
    }
    used += snprintf(extra + used, sizeof extra - used, ",\"board.enroll.v1\"%s]", s->enrolled ? ",\"board.enrolled.v1\"" : "");
    s->state = TP_SESSION_REQUESTED;
    s->started_ms = s->last_received_ms = s->last_heartbeat_ms = now_ms;
    if (!write_json(s, s->direct ? "sessionRequest" : "pairRequest", extra, now_ms)) {
        tp_session_stop(s, "Cannot reach the Mac");
        return;
    }
    notify(s, NULL);
}

static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool parse_uuid(const char *text, uint8_t out[16]) {
    if (!text || strlen(text) != 36) return false;
    int index = 0;
    for (int i = 0; i < 36; ) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (text[i] != '-') return false; i++; continue; }
        int high = hex_value(text[i]), low = hex_value(text[i + 1]);
        if (high < 0 || low < 0) return false;
        out[index++] = (uint8_t)(high << 4 | low);
        i += 2;
    }
    return index == 16;
}

/// Returns false for a malformed context, which ends the session.
static bool read_app_context(tp_session_t *s, const cJSON *message, bool *changed) {
    const cJSON *context = cJSON_GetObjectItemCaseSensitive(message, "appContext");
    if (!context) return true;
    const cJSON *app = cJSON_GetObjectItemCaseSensitive(context, "app");
    const cJSON *token = cJSON_GetObjectItemCaseSensitive(context, "token");
    uint8_t bytes[16];
    if (!(s->capabilities & TP_CAP_APP_CONTROLS) || !cJSON_IsString(app) || !cJSON_IsString(token)
        || !parse_uuid(token->valuestring, bytes)) return false;
    tp_app_t value = TP_APP_OTHER;   // An app this firmware does not know gets the generic controls.
    for (int i = 0; i < TP_APP_COUNT; i++) if (strcmp(app->valuestring, tp_app_names[i]) == 0) value = (tp_app_t)i;
    if (!s->has_app || s->app != value || memcmp(s->app_token, bytes, 16) != 0) *changed = true;
    s->has_app = true; s->app = value; memcpy(s->app_token, bytes, 16);
    return true;
}

const char tp_mac_resting[] = "The Mac is asleep or closed";

static void handle_json(tp_session_t *s, const char *text, uint64_t now_ms) {
    cJSON *message = cJSON_Parse(text);
    const cJSON *version = cJSON_GetObjectItemCaseSensitive(message, "version");
    const cJSON *session = cJSON_GetObjectItemCaseSensitive(message, "session");
    const cJSON *sequence = cJSON_GetObjectItemCaseSensitive(message, "sequence");
    const cJSON *timestamp = cJSON_GetObjectItemCaseSensitive(message, "timestampMilliseconds");
    const cJSON *type = cJSON_GetObjectItemCaseSensitive(message, "type");
    const char *failure = NULL;
    bool changed = false, enrolled = false;
    if (!cJSON_IsNumber(version) || version->valuedouble != 2 || !cJSON_IsString(session)
        || strcmp(session->valuestring, s->session) != 0 || !cJSON_IsNumber(sequence) || !cJSON_IsNumber(timestamp)
        || !cJSON_IsString(type) || sequence->valuedouble <= (double)s->received
        || timestamp->valuedouble < (double)s->received_timestamp) {
        failure = "Invalid message from the Mac";
    } else {
        s->received = (uint64_t)sequence->valuedouble;
        s->received_timestamp = (uint64_t)timestamp->valuedouble;
        s->last_received_ms = now_ms;
        const char *kind = type->valuestring;
        if (strcmp(kind, s->direct ? "sessionAccept" : "pairAccept") == 0 && s->state == TP_SESSION_REQUESTED) {
            const cJSON *capabilities = cJSON_GetObjectItemCaseSensitive(message, "capabilities");
            const cJSON *item;
            int basic = 0;
            cJSON_ArrayForEach(item, capabilities) {
                if (!cJSON_IsString(item)) continue;
                for (size_t i = 0; i < CAPABILITY_COUNT; i++) {
                    if (strcmp(item->valuestring, capability_table[i].name) != 0) continue;
                    s->capabilities |= capability_table[i].bit;
                    if (i < BASIC_COUNT) basic++;
                }
            }
            if (basic == BASIC_COUNT) s->capabilities |= TP_CAP_BASIC;
            if (!(s->capabilities & TP_CAP_BASIC) || !(s->capabilities & TP_CAP_BINARY)) {
                failure = "This Mac app is too old for the board";
            } else if (!read_app_context(s, message, &changed)) {
                failure = "Invalid message from the Mac";
            } else {
                s->state = TP_SESSION_CONNECTED;
                s->last_heartbeat_ms = now_ms;
                changed = true;
            }
        } else if (strcmp(kind, "pairReject") == 0 && s->state == TP_SESSION_REQUESTED) {
            failure = "The Mac declined the connection";
        } else if (strcmp(kind, "heartbeat") == 0 && s->state == TP_SESSION_CONNECTED) {
            if (!read_app_context(s, message, &changed)) failure = "Invalid message from the Mac";
        } else if (strcmp(kind, "enroll") == 0 && s->state == TP_SESSION_CONNECTED && s->direct) {
            // The cable is the trust anchor: a key is never accepted wirelessly.
            const cJSON *enrollment = cJSON_GetObjectItemCaseSensitive(message, "enrollment");
            const cJSON *key = cJSON_GetObjectItemCaseSensitive(enrollment, "key");
            const cJSON *host = cJSON_GetObjectItemCaseSensitive(enrollment, "host");
            const cJSON *name = cJSON_GetObjectItemCaseSensitive(enrollment, "name");
            uint8_t bytes[32];
            bool valid = cJSON_IsString(key) && strlen(key->valuestring) == 64 && cJSON_IsString(host)
                && host->valuestring[0] && strlen(host->valuestring) <= 255 && cJSON_IsString(name) && strlen(name->valuestring) <= 64;
            for (int i = 0; valid && i < 32; i++) {
                int high = hex_value(key->valuestring[i * 2]), low = hex_value(key->valuestring[i * 2 + 1]);
                if (high < 0 || low < 0) valid = false; else bytes[i] = (uint8_t)(high << 4 | low);
            }
            if (!valid) failure = "Invalid message from the Mac";
            else if (s->callbacks.enroll && s->callbacks.enroll(s->callbacks.context, bytes, host->valuestring, name->valuestring)) {
                s->enrolled = true;
                enrolled = true;
            }
        } else if (strcmp(kind, "disconnect") == 0) {
            failure = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(message, "sleeping")) ? tp_mac_resting : "The Mac disconnected";
        } else {
            failure = "Unexpected message from the Mac";
        }
    }
    cJSON_Delete(message);
    if (failure) { tp_session_stop(s, failure); return; }
    if (enrolled && !write_json(s, "enrolled", NULL, now_ms)) { tp_session_stop(s, "Cannot reach the Mac"); return; }
    if (changed || enrolled) notify(s, NULL);
}

void tp_session_receive(tp_session_t *s, const uint8_t *bytes, size_t length, uint64_t now_ms) {
    for (size_t i = 0; i < length && s->state != TP_SESSION_IDLE; i++) {
        uint8_t byte = bytes[i];
        if (s->buffered == 0) s->binary_size = byte == 0xd3 ? 0 : -1;
        if (s->binary_size >= 0) {
            // The only binary frame a client can receive is the 28-byte input
            // acknowledgment, which this firmware never requests.
            s->buffer[s->buffered++] = byte;
            if (s->buffered == 4) {
                s->binary_size = s->buffer[2] << 8 | s->buffer[3];
                if (s->buffer[1] != 2 || s->binary_size != 28) { tp_session_stop(s, "Invalid message from the Mac"); return; }
            }
            if (s->buffered >= 4 && (int)s->buffered == s->binary_size) { s->buffered = 0; s->last_received_ms = now_ms; }
        } else if (byte == '\n') {
            s->buffer[s->buffered] = 0;
            s->buffered = 0;
            handle_json(s, (const char *)s->buffer, now_ms);
        } else if (s->buffered < TP_JSON_MAX) {
            s->buffer[s->buffered++] = byte;
        } else {
            tp_session_stop(s, "Invalid message from the Mac");
        }
    }
}

void tp_session_tick(tp_session_t *s, uint64_t now_ms) {
    if (s->state == TP_SESSION_IDLE) return;
    uint64_t limit = s->state == TP_SESSION_CONNECTED ? 3500 : 60000;
    if (now_ms - s->last_received_ms > limit) { tp_session_stop(s, "Connection timed out"); return; }
    if (s->state == TP_SESSION_CONNECTED && now_ms - s->last_heartbeat_ms >= 1000) {
        s->last_heartbeat_ms = now_ms;
        if (!write_json(s, "heartbeat", NULL, now_ms)) tp_session_stop(s, "Cannot reach the Mac");
    }
}

static bool negotiated(const tp_session_t *s, tp_kind_t kind) {
    switch (kind) {
    case TP_ACTION: return s->capabilities & TP_CAP_STANDARD_ACTIONS;
    case TP_MAGNIFY: return s->capabilities & TP_CAP_PINCH;
    case TP_PAGE_SWIPE: return s->capabilities & TP_CAP_PAGES;
    case TP_MISSION_CONTROL: return s->capabilities & TP_CAP_MISSION_CONTROL;
    case TP_SHOW_DESKTOP: return s->capabilities & TP_CAP_SHOW_DESKTOP;
    case TP_APP_CONTROL: return s->capabilities & TP_CAP_APP_CONTROLS;
    default: return s->capabilities & TP_CAP_BASIC;
    }
}

bool tp_session_send(tp_session_t *s, const tp_command_t *command, uint64_t now_ms) {
    if (s->state != TP_SESSION_CONNECTED || !negotiated(s, command->kind)) return true;
    tp_command_t bounded = *command;
    if (bounded.kind == TP_SCROLL && !(s->capabilities & TP_CAP_HIGH_RANGE_SCROLL)) {
        bounded.dx = bounded.dx > 128 ? 128 : (bounded.dx < -128 ? -128 : bounded.dx);
        bounded.dy = bounded.dy > 128 ? 128 : (bounded.dy < -128 ? -128 : bounded.dy);
    }
    uint8_t frame[TP_COMPACT_MAX];
    size_t size = tp_encode_compact(&bounded, s->sent + 1, now_ms, frame);
    if (size == 0) return true;
    s->sent++;
    if (!s->callbacks.write(frame, size, s->callbacks.context)) {
        tp_session_stop(s, "Cannot reach the Mac");
        return false;
    }
    return true;
}
