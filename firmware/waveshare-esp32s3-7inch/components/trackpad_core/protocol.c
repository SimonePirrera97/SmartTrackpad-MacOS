// Compact input v1 encoding and command validity. The normative layout is in
// docs/developer-notes.md ("Compact input v1 contract"); the Swift counterpart
// is packages/TrackpadProtocol/CompactInput.swift.
#include "trackpad_core.h"
#include <math.h>
#include <string.h>

const char *const tp_app_names[TP_APP_COUNT] = { "other", "vscode", "terminal", "safari", "spotify", "finder" };
const char *const tp_app_titles[TP_APP_COUNT] = { "Editing", "VS Code", "Terminal", "Safari", "Spotify", "Finder" };
const char *const tp_app_action_names[TP_APP_ACTION_COUNT] = {
    "save", "compile", "delete", "deleteWord", "enter", "newTab", "closeTab", "playPause",
    "previousTrack", "nextTrack", "volumeDown", "volumeUp", "newFolder", "trash" };
const char *const tp_app_action_labels[TP_APP_ACTION_COUNT] = {
    "Save", "Compile", "Delete", "Delete Word", "Enter", "New Tab", "Close Tab", "Play / Pause",
    "Previous", "Next", "Volume Down", "Volume Up", "New Folder", "Move to Trash" };

static bool app_accepts(tp_app_t app, tp_app_action_t action) {
    switch (app) {
    case TP_APP_VSCODE: return action == TP_SAVE || action == TP_DELETE;
    case TP_APP_TERMINAL: return action == TP_DELETE_WORD || action == TP_ENTER;
    case TP_APP_SAFARI: return action == TP_SAVE || action == TP_NEW_TAB || action == TP_CLOSE_TAB;
    case TP_APP_SPOTIFY: return action >= TP_PLAY_PAUSE && action <= TP_VOLUME_UP;
    case TP_APP_FINDER: return action == TP_NEW_FOLDER || action == TP_TRASH;
    default: return false;
    }
}

bool tp_command_valid(const tp_command_t *c) {
    bool timed = c->kind == TP_SCROLL || c->kind == TP_PAGE_SWIPE || c->kind == TP_MISSION_CONTROL;
    if (!timed && (c->has_sample_age || c->has_interval)) return false;
    if (c->has_interval) {
        if (!isfinite(c->interval_ms) || c->interval_ms <= 0 || c->interval_ms > 250) return false;
        if (c->phase != TP_BEGAN && c->phase != TP_CHANGED) return false;
    }
    bool ending = c->phase == TP_ENDED || c->phase == TP_CANCELLED;
    switch (c->kind) {
    case TP_MOVE: return isfinite(c->dx) && isfinite(c->dy) && fabs(c->dx) <= 128 && fabs(c->dy) <= 128;
    case TP_CLICK: return c->button <= TP_RIGHT && c->count >= 1 && c->count <= 3;
    case TP_BUTTON: return c->button <= TP_RIGHT;
    case TP_SCROLL:
        return isfinite(c->dx) && isfinite(c->dy) && fabs(c->dx) <= 2048 && fabs(c->dy) <= 2048
            && c->phase <= TP_CANCELLED && (!ending || (c->dx == 0 && c->dy == 0));
    case TP_RELEASE_ALL: case TP_STOP_MOMENTUM: case TP_SHOW_DESKTOP: return true;
    case TP_ACTION: return c->action <= TP_QUIT;
    case TP_MAGNIFY:
        return isfinite(c->value) && fabs(c->value) <= 0.5 && c->phase <= TP_CANCELLED
            && (c->phase == TP_CHANGED || c->value == 0);
    case TP_PAGE_SWIPE: case TP_MISSION_CONTROL:
        return isfinite(c->value) && fabs(c->value) <= 3 && c->phase <= TP_CANCELLED
            && (c->phase != TP_BEGAN || c->value == 0);
    case TP_APP_CONTROL: return c->app < TP_APP_COUNT && c->app_action < TP_APP_ACTION_COUNT && app_accepts(c->app, c->app_action);
    }
    return false;
}

static uint8_t *put(uint8_t *out, uint64_t value, int bytes) {
    for (int shift = (bytes - 1) * 8; shift >= 0; shift -= 8) *out++ = (uint8_t)(value >> shift);
    return out;
}
static uint8_t *put_float(uint8_t *out, double value) {
    float narrowed = (float)value;
    uint32_t bits; memcpy(&bits, &narrowed, 4);
    return put(out, bits, 4);
}

size_t tp_encode_compact(const tp_command_t *c, uint64_t sequence, uint64_t timestamp_ms, uint8_t out[TP_COMPACT_MAX]) {
    if (sequence == 0 || !tp_command_valid(c)) return 0;
    uint8_t *p = out;
    *p++ = 0xd3; *p++ = 1; *p++ = 0; *p++ = 0;
    p = put(p, sequence, 8);
    p = put(p, timestamp_ms, 8);
    *p++ = (uint8_t)c->kind;
    switch (c->kind) {
    case TP_SCROLL: *p++ = (uint8_t)c->phase; // fallthrough
    case TP_MOVE: p = put_float(p, c->dx); p = put_float(p, c->dy); break;
    case TP_CLICK: *p++ = (uint8_t)c->button; *p++ = c->count; break;
    case TP_BUTTON: *p++ = (uint8_t)c->button; *p++ = c->pressed ? 1 : 0; break;
    case TP_ACTION: *p++ = (uint8_t)c->action; break;
    case TP_MAGNIFY: case TP_PAGE_SWIPE: case TP_MISSION_CONTROL:
        *p++ = (uint8_t)c->phase; p = put_float(p, c->value); break;
    case TP_APP_CONTROL:
        *p++ = (uint8_t)c->app; *p++ = (uint8_t)c->app_action;
        memcpy(p, c->token, 16); p += 16; break;
    case TP_RELEASE_ALL: case TP_STOP_MOMENTUM: case TP_SHOW_DESKTOP: break;
    }
    if (c->kind == TP_SCROLL || c->kind == TP_PAGE_SWIPE || c->kind == TP_MISSION_CONTROL) {
        // The age is relative to the enclosing timestamp, so it can never lie in the future.
        bool age = c->has_sample_age && c->sample_age_ms <= timestamp_ms;
        bool interval = c->has_interval && (float)c->interval_ms > 0;
        *p++ = (uint8_t)((age ? 1 : 0) | (interval ? 2 : 0));
        if (age) p = put(p, c->sample_age_ms, 4);
        if (interval) p = put_float(p, c->interval_ms);
    }
    size_t size = (size_t)(p - out);
    out[2] = (uint8_t)(size >> 8); out[3] = (uint8_t)size;
    return size;
}
