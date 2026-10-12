// Portable Smart Trackpad client core: gesture recognition, wire encoding and
// the session state machine. No ESP-IDF, display or transport dependencies, so
// it also compiles on a desktop for the fixture checks in test/host_test.c.
// Behavior mirrors packages/GestureCore and packages/TrackpadProtocol.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Commands -------------------------------------------------------------

// Numeric values are the compact input v1 identifiers; never reorder.
typedef enum {
    TP_MOVE, TP_CLICK, TP_BUTTON, TP_SCROLL, TP_RELEASE_ALL, TP_STOP_MOMENTUM,
    TP_ACTION, TP_MAGNIFY, TP_PAGE_SWIPE, TP_MISSION_CONTROL, TP_SHOW_DESKTOP, TP_APP_CONTROL,
} tp_kind_t;
typedef enum { TP_BEGAN, TP_CHANGED, TP_ENDED, TP_CANCELLED } tp_phase_t;
typedef enum { TP_LEFT, TP_RIGHT } tp_button_t;
typedef enum { TP_COPY, TP_CUT, TP_PASTE, TP_UNDO, TP_REDO, TP_ACTION_MISSION_CONTROL, TP_QUIT } tp_action_t;
typedef enum { TP_APP_OTHER, TP_APP_VSCODE, TP_APP_TERMINAL, TP_APP_SAFARI, TP_APP_SPOTIFY, TP_APP_FINDER, TP_APP_COUNT } tp_app_t;
typedef enum {
    TP_SAVE, TP_COMPILE, TP_DELETE, TP_DELETE_WORD, TP_ENTER, TP_NEW_TAB, TP_CLOSE_TAB, TP_PLAY_PAUSE,
    TP_PREVIOUS_TRACK, TP_NEXT_TRACK, TP_VOLUME_DOWN, TP_VOLUME_UP, TP_NEW_FOLDER, TP_TRASH, TP_APP_ACTION_COUNT,
} tp_app_action_t;

typedef struct {
    tp_kind_t kind;
    double dx, dy;            // move, scroll
    tp_button_t button;       // click, button
    bool pressed;             // button
    uint8_t count;            // click: 1...3
    tp_phase_t phase;         // scroll, magnify, navigation
    tp_action_t action;       // action
    double value;             // magnify increment, or absolute navigation progress
    bool has_sample_age;      // scroll, navigation: age of the touch sample
    uint32_t sample_age_ms;
    bool has_interval;        // scroll, navigation: time since the previous sample
    double interval_ms;
    tp_app_t app;             // appControl
    tp_app_action_t app_action;
    uint8_t token[16];
} tp_command_t;

typedef void (*tp_emit_t)(const tp_command_t *command, void *context);

// ---- Gesture engine -------------------------------------------------------

#define TP_MAX_TOUCHES 10

// Coordinates use 1000 units per shortest surface dimension; +y points down.
typedef struct { int id; double x, y; } tp_touch_t;
typedef struct { int count; tp_touch_t items[TP_MAX_TOUCHES]; } tp_touches_t;

typedef struct {
    bool tap_to_click, two_finger_tap, hold_to_drag, three_finger_drag;
    bool pinch, mission_control, page_swipes;
    /// Contacts for Mission Control: 3 as on the iPad, or 4 so that it can
    /// coexist with three-finger drag. Page swipes always use 3.
    int mission_fingers;
    /// A hold-drag survives a second finger: either finger moves the pointer and
    /// the button stays down until both have lifted. Off on the iPad, where a
    /// second finger ends the drag.
    bool drag_second_finger;
    double hold_duration, tap_duration, movement_threshold;
} tp_options_t;

typedef struct {
    tp_options_t options;
    // Private state.
    tp_touches_t previous, origins;
    bool pointer_has; int pointer_id; double pointer_x, pointer_y;
    double began; int peak; double travel;
    bool dragging; int drag_contacts; bool scrolling, suppressed;
    bool tap_has; double tap_time, tap_x, tap_y; int tap_count;
    bool updated; double last_update;
    bool base_has; double base_distance, base_angle;
    bool anchor_has; double anchor_x, anchor_y, anchor_time;
    int pinch_count; int pinch_ids[2]; double pinch_distance, pinch_angle; bool pinch_cancelled;
    bool pinching; double previous_scale;
    int nav_ids_count; int nav_ids[4]; bool nav_origin_has; double nav_origin_x, nav_origin_y;
    int nav_axis; double nav_progress; bool nav_suppressed;
} tp_engine_t;

tp_options_t tp_default_options(void);
void tp_engine_init(tp_engine_t *engine);
/// Complete contact snapshot and monotonic seconds in; commands out.
void tp_engine_update(tp_engine_t *engine, const tp_touches_t *touches, double time, tp_emit_t emit, void *context);
/// Releases anything held and forgets all contacts.
void tp_engine_cancel(tp_engine_t *engine, tp_emit_t emit, void *context);
/// When a stationary finger becomes a drag; call update again at that time. False if none.
bool tp_engine_hold_deadline(const tp_engine_t *engine, double *deadline);

/// Applies pointer or scroll speed. Scroll beyond the packet bound is split.
void tp_scale(const tp_command_t *command, double factor, tp_emit_t emit, void *context);

// ---- Wire encoding --------------------------------------------------------

#define TP_COMPACT_MAX 128
#define TP_JSON_MAX 4096

bool tp_command_valid(const tp_command_t *command);
/// Compact input v1 frame. Returns its length, or 0 if the command is invalid.
size_t tp_encode_compact(const tp_command_t *command, uint64_t sequence, uint64_t timestamp_ms, uint8_t out[TP_COMPACT_MAX]);

extern const char *const tp_app_names[TP_APP_COUNT];           // wire names
extern const char *const tp_app_titles[TP_APP_COUNT];          // display names
extern const char *const tp_app_action_names[TP_APP_ACTION_COUNT];
extern const char *const tp_app_action_labels[TP_APP_ACTION_COUNT];

// ---- Session --------------------------------------------------------------

typedef enum { TP_SESSION_IDLE, TP_SESSION_REQUESTED, TP_SESSION_CONNECTED } tp_session_state_t;

enum {
    TP_CAP_STANDARD_ACTIONS = 1 << 0, TP_CAP_PINCH = 1 << 1, TP_CAP_PAGES = 1 << 2,
    TP_CAP_MISSION_CONTROL = 1 << 3, TP_CAP_SHOW_DESKTOP = 1 << 4, TP_CAP_APP_CONTROLS = 1 << 5,
    TP_CAP_BINARY = 1 << 6, TP_CAP_HIGH_RANGE_SCROLL = 1 << 7, TP_CAP_BASIC = 1 << 8,
};

typedef struct {
    /// Sends bytes to the Mac. Returns false if the link cannot take them.
    bool (*write)(const uint8_t *bytes, size_t length, void *context);
    /// The session started, ended (reason is never NULL then) or the Mac's front app changed.
    void (*changed)(void *context, const char *reason);
    void *context;
    /// Cable only: the Mac hands over this board's permanent key together with
    /// its network name and display name. Store them; return false on failure.
    bool (*enroll)(void *context, const uint8_t key[32], const char *host, const char *name);
} tp_session_callbacks_t;

typedef struct {
    tp_session_callbacks_t callbacks;
    tp_session_state_t state;
    bool direct;                 // cable: sessionRequest; wireless: pairRequest with a code
    bool enrolled;               // this board holds a key; set by the application
    char session[37];
    char code[7];
    uint64_t sent, received, received_timestamp;
    uint64_t last_received_ms, last_heartbeat_ms, started_ms;
    uint32_t capabilities;
    bool has_app; tp_app_t app; uint8_t app_token[16];
    uint8_t buffer[TP_JSON_MAX + 1]; size_t buffered; int binary_size;
} tp_session_t;

void tp_session_init(tp_session_t *session, tp_session_callbacks_t callbacks);
/// `uuid` is a fresh random UUID string. `code` is NULL for a cable session,
/// or six digits for a wireless one. `proof` is NULL, or the 64 hexadecimal
/// characters of HMAC-SHA256(board key, "smart-trackpad-board-proof-v1:" + uuid)
/// with which a remembered board is accepted without approval.
void tp_session_start(tp_session_t *session, const char *uuid, const char *code, const char *proof, uint64_t now_ms);
void tp_session_receive(tp_session_t *session, const uint8_t *bytes, size_t length, uint64_t now_ms);
/// Call a few times a second: heartbeats and timeouts.
void tp_session_tick(tp_session_t *session, uint64_t now_ms);
/// Drops commands the Mac did not negotiate. False if the link refused the bytes.
bool tp_session_send(tp_session_t *session, const tp_command_t *command, uint64_t now_ms);
void tp_session_stop(tp_session_t *session, const char *reason);
/// The reason passed to `changed` when the Mac ended the session because it is
/// asleep or its lid is closed. Compare by address.
extern const char tp_mac_resting[];

#ifdef __cplusplus
}
#endif
