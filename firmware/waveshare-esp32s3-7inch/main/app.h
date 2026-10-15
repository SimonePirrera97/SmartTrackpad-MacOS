// State shared by the firmware's tasks. Lock order: LVGL lock, then core lock.
// The touch and USB tasks take only the core lock, so they never wait on drawing.
#pragma once
#include "trackpad_core.h"
#include "ui_pointer_queue.h"

#define STRIP_WIDTH 280
#define PAD_WIDTH (1024 - STRIP_WIDTH)
/// The row of connection buttons across the top; touches in it belong to LVGL.
#define BAR_HEIGHT 68

/// Saved in flash. Same choices and defaults as the iPad's settings.
typedef struct {
    uint32_t version;
    double sensitivity, scroll_speed;
    bool natural_scroll, tap_to_click, two_finger_tap, hold_to_drag, three_finger_drag;
    bool mission_control, page_swipes, pinch;
    uint8_t brightness;           // percent, while a computer is on the USB port
    uint8_t brightness_battery;   // percent, otherwise: lowest by default to save the battery
} app_settings_t;
#define APP_SETTINGS_VERSION 7

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
/// The user tapped the power button: screen dark and offline until the next touch.
extern volatile bool g_asleep;
/// The Mac ended the session for sleep/lid close; its rising edge requests board deep sleep.
extern volatile bool g_host_asleep;

void core_lock(void);
void core_unlock(void);
uint64_t app_now_ms(void);

/// The contact LVGL sees: only fingers that landed on the button strip.
void touch_ui_read(ui_pointer_t *pointer, bool *more);

/// Which transport currently carries g_session.
typedef enum { LINK_NONE, LINK_USB, LINK_WIFI, LINK_BLE } app_link_t;
extern volatile app_link_t g_link;

void touch_start(void);
void ui_start(void);
void usb_link_start(void);
void uart_link_start(void);
bool uart_link_open(void);
bool uart_link_write(const uint8_t *bytes, size_t length);
bool usb_link_write(const uint8_t *bytes, size_t length);
/// The Mac has the serial port open.
bool usb_link_open(void);
/// Notices an unplugged cable. Core lock held.
void usb_link_poll(void);
/// A computer is actively driving the USB port (not merely supplying power).
bool usb_link_host_present(void);
/// Includes a mounted computer whose USB bus is suspended.
bool usb_link_computer_attached(void);

// The one route used to reach the Mac; the radio of any other route is off.
// Not saved: at startup the board settles on USB if a computer drives the port,
// otherwise it tries Wi-Fi and then Bluetooth once. After that only the top
// bar's menu changes it.
typedef enum { ROUTE_USB, ROUTE_WIFI, ROUTE_BLUETOOTH } app_route_t;
extern volatile app_route_t g_route;
/// The Wireless page is open: keep Wi-Fi up so networks can be listed and joined.
extern volatile bool g_wifi_setup;
/// Brightness for the current power source, and the setting that holds it.
uint8_t app_brightness(void);
void app_set_brightness(uint8_t percent);
/// Estimated battery charge 0...100, or -1 until a valid voltage is measured.
extern volatile int g_battery_percent;

// Remembered Mac: the key it handed over by cable, and where to find it.
typedef struct { bool valid; uint8_t key[32]; char host[256]; char name[65]; } app_mac_t;
extern app_mac_t g_mac;
bool app_enroll(void *context, const uint8_t key[32], const char *host, const char *name);
void app_forget_mac(void);
void app_new_uuid(char uuid[37]);

// Shared wireless session (TLS with the board key); see secure_link.c.
typedef struct {
    app_link_t link;
    const char *lost;                                    // shown when the route drops
    int (*send)(void *context, const unsigned char *bytes, size_t length);    // mbedTLS BIO
    int (*receive)(void *context, unsigned char *bytes, size_t length);
    void (*wait)(void *context);                         // a few milliseconds, or until readable
    bool (*alive)(void *context);
    void *context;
} secure_transport_t;
void secure_link_init(void);
/// Runs a whole session and returns when it ends. False if TLS never came up.
bool secure_session(const app_mac_t *mac, const secure_transport_t *transport);
bool secure_link_write(const uint8_t *bytes, size_t length);
bool secure_link_idle(void);

/// Sends a command, merging pointer and scroll motion while a slow route is busy. Core lock held.
void app_send(const tp_command_t *command);
/// The route caught up: send whatever was merged meanwhile.
void app_flush(void);

// Wi-Fi.
void wifi_link_start(void);
/// Switches the Wi-Fi radio itself on or off.
void wifi_link_power(bool on);

// Bluetooth LE.
void ble_link_start(void);
/// Bytes are still on their way to the Mac.
bool ble_link_busy(void);
void ble_link_status(char *text, size_t size);
/// One line for the screen, such as "Connected to HomeNet".
void wifi_link_status(char *text, size_t size);
/// Starts a scan; results arrive in wifi_link_networks once `scanning` clears.
void wifi_link_scan(void);
int wifi_link_networks(char names[][33], int capacity, bool *scanning);
/// `password` may be NULL for a network the board has joined before.
void wifi_link_join(const char *name, const char *password);
bool wifi_link_saved(const char *name);
/// Gesture options are the user's settings limited to what the Mac negotiated. Core lock held.
void app_apply_capabilities(void);
void app_save_settings(void);
/// The board belongs on the USB bus: USB is the route, or startup is still looking for one.
bool app_usb_wanted(void);
/// The user picks the route, ending a session that runs over another one.
void app_set_route(app_route_t route);
/// Ends the session and stays offline, or goes back online.
void app_set_paused(bool paused);
/// Offline with the screen dark until the touch task sees a new touch and wakes.
void app_sleep(void);
void app_enter_deep_sleep(void);
bool app_woke_from_sleep(void);
void app_wake(void);
