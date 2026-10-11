// State shared by the firmware's tasks. Lock order: LVGL lock, then core lock.
// The touch and USB tasks take only the core lock, so they never wait on drawing.
#pragma once
#include "trackpad_core.h"

#define STRIP_WIDTH 280
#define PAD_WIDTH (1024 - STRIP_WIDTH)

/// Saved in flash. Same choices and defaults as the iPad's settings.
typedef struct {
    uint32_t version;
    double sensitivity, scroll_speed;
    bool natural_scroll, tap_to_click, two_finger_tap, hold_to_drag, three_finger_drag;
    bool mission_control, page_swipes, pinch;
} app_settings_t;
#define APP_SETTINGS_VERSION 2

extern tp_session_t g_session;
extern tp_engine_t g_engine;
extern app_settings_t g_settings;
/// Set whenever the session state or app context changes; the UI polls it.
extern volatile bool g_ui_dirty;
extern char g_status[96];
extern volatile bool g_dragging, g_hold_pending;
/// A full-screen panel is open: every touch belongs to LVGL, none to the pad.
extern volatile bool g_ui_modal;
/// The user tapped Disconnect; stay offline until Connect.
extern volatile bool g_paused;

void core_lock(void);
void core_unlock(void);
uint64_t app_now_ms(void);

/// The contact LVGL sees: only fingers that landed on the button strip.
typedef struct { bool pressed; int16_t x, y; } ui_pointer_t;
extern volatile ui_pointer_t g_ui_pointer;

/// Which transport currently carries g_session. USB always wins: plugging the
/// cable in takes the session over from Wi-Fi.
typedef enum { LINK_NONE, LINK_USB, LINK_WIFI } app_link_t;
extern volatile app_link_t g_link;

void touch_start(void);
void ui_start(void);
void usb_link_start(void);
bool usb_link_write(const uint8_t *bytes, size_t length);
/// The Mac has the serial port open.
bool usb_link_open(void);
/// Called with the core lock held when the session's transport should (re)start.
void usb_link_begin(void);
/// Notices an unplugged cable. Core lock held.
void usb_link_poll(void);

// Remembered Mac: the key it handed over by cable, and where to find it.
typedef struct { bool valid; uint8_t key[32]; char host[256]; char name[65]; } app_mac_t;
extern app_mac_t g_mac;
bool app_enroll(void *context, const uint8_t key[32], const char *host, const char *name);
void app_forget_mac(void);
void app_new_uuid(char uuid[37]);

// Wi-Fi.
void wifi_link_start(void);
bool wifi_link_write(const uint8_t *bytes, size_t length);
/// One line for the screen, such as "Connected to HomeNet".
void wifi_link_status(char *text, size_t size);
/// Starts a scan; results arrive in wifi_link_networks once `scanning` clears.
void wifi_link_scan(void);
int wifi_link_networks(char names[][33], int capacity, bool *scanning);
void wifi_link_join(const char *name, const char *password);
/// Gesture options are the user's settings limited to what the Mac negotiated. Core lock held.
void app_apply_capabilities(void);
void app_save_settings(void);
/// Ends the session and stays offline, or goes back online.
void usb_link_set_paused(bool paused);
