#include "app.h"
#include <stdio.h>
#include <string.h>
#include "board.h"
#include "esp_log.h"
#include "esp_lvgl_port.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "nvs_flash.h"

tp_session_t g_session;
tp_engine_t g_engine;
app_settings_t g_settings = {
    .version = APP_SETTINGS_VERSION, .sensitivity = 1, .scroll_speed = 1, .natural_scroll = true,
    // Three fingers drag; Mission Control uses four so both can be on. Page
    // swipes share three fingers with drag, so they start off.
    .tap_to_click = true, .two_finger_tap = true, .hold_to_drag = true, .three_finger_drag = true,
    .mission_control = true, .page_swipes = false, .pinch = true, .brightness = 100, .brightness_battery = 10,
};
volatile bool g_ui_dirty = true, g_dragging, g_hold_pending, g_ui_modal, g_paused, g_asleep, g_host_asleep;
char g_status[96];
volatile ui_pointer_t g_ui_pointer;
volatile app_link_t g_link;
app_mac_t g_mac;
volatile app_route_t g_route = ROUTE_USB;
volatile bool g_wifi_setup;
volatile int g_battery_percent = -1;

static SemaphoreHandle_t core_mutex;
void core_lock(void) { xSemaphoreTakeRecursive(core_mutex, portMAX_DELAY); }
void core_unlock(void) { xSemaphoreGiveRecursive(core_mutex); }
uint64_t app_now_ms(void) { return (uint64_t)(esp_timer_get_time() / 1000); }

void app_apply_capabilities(void) {
    uint32_t caps = g_session.capabilities;
    tp_options_t *o = &g_engine.options;
    o->tap_to_click = g_settings.tap_to_click;
    o->two_finger_tap = g_settings.two_finger_tap;
    o->hold_to_drag = g_settings.hold_to_drag;
    o->three_finger_drag = g_settings.three_finger_drag;
    o->mission_fingers = 4;
    o->drag_second_finger = true;
    o->pinch = g_settings.pinch && (caps & TP_CAP_PINCH);
    o->mission_control = g_settings.mission_control && (caps & TP_CAP_MISSION_CONTROL);
    o->page_swipes = g_settings.page_swipes && (caps & TP_CAP_PAGES);
}

void app_save_settings(void) {
    nvs_handle_t handle;
    if (nvs_open("trackpad", NVS_READWRITE, &handle) != ESP_OK) return;
    core_lock();
    app_settings_t copy = g_settings;
    core_unlock();
    nvs_set_blob(handle, "settings", &copy, sizeof copy);
    nvs_commit(handle);
    nvs_close(handle);
}

// The startup pick is over: from here on only the user changes the route.
static bool route_settled;

/// Core lock held.
static void set_route(app_route_t route) {
    g_route = route;
    app_link_t only = route == ROUTE_USB ? LINK_USB : route == ROUTE_WIFI ? LINK_WIFI : LINK_BLE;
    if (g_link != LINK_NONE && g_link != only) tp_session_stop(&g_session, "Changing route");
    g_ui_dirty = true;
}

void app_set_route(app_route_t route) {
    core_lock();
    route_settled = true;
    set_route(route);
    core_unlock();
}

bool app_usb_wanted(void) { return !g_paused && (g_route == ROUTE_USB || !route_settled); }

/// Startup only, core lock held: USB if a computer drives the port; otherwise
/// Wi-Fi, then Bluetooth if Wi-Fi gives no session in time; USB again if neither
/// does. A session, or anything the user does to the connection, ends it. The
/// board stays on the USB bus meanwhile, so a computer that is slow to start, or
/// a cable plugged in a little late, still gets USB.
static void pick_startup_route(uint64_t now) {
    const uint64_t usb_window = 4000, wifi_window = 25000, bluetooth_window = 40000;
    static uint64_t step_started;   // the USB step starts at power-on
    if (route_settled) return;
    uint64_t waited = now - step_started;
    if (g_paused) route_settled = true;
    else if (usb_link_host_present()) { set_route(ROUTE_USB); route_settled = true; }
    else if (g_link != LINK_NONE) route_settled = true;
    else if (g_route == ROUTE_USB) {
        // The radios need the key the Mac hands over by cable.
        if (waited > usb_window && !g_mac.valid) route_settled = true;
        else if (waited > usb_window) { set_route(ROUTE_WIFI); step_started = now; }
    } else if (g_route == ROUTE_WIFI) {
        if (waited > wifi_window) { set_route(ROUTE_BLUETOOTH); step_started = now; }
    } else if (waited > bluetooth_window) {
        set_route(ROUTE_USB);
        route_settled = true;
    }
    if (route_settled) ESP_LOGI("route", "startup settled on %s", g_route == ROUTE_USB ? "USB" : g_route == ROUTE_WIFI ? "Wi-Fi" : "Bluetooth");
}

void app_set_paused(bool paused) {
    core_lock();
    g_paused = paused;
    // usb_link_poll leaves or rejoins the bus to match; the power task the radio.
    if (paused) tp_session_stop(&g_session, "Disconnected");
    snprintf(g_status, sizeof g_status, paused ? "Disconnected" : "Waiting for the Mac");
    g_ui_dirty = true;
    core_unlock();
}

static bool paused_before_sleep;

void app_sleep(void) {
    core_lock();
    paused_before_sleep = g_paused;
    g_asleep = true;   // the touch task switches the backlight off
    app_set_paused(true);
    core_unlock();
}

void app_wake(void) {
    core_lock();
    g_asleep = false;
    app_set_paused(paused_before_sleep);
    core_unlock();
}

void app_new_uuid(char uuid[37]) {
    uint8_t r[16];
    esp_fill_random(r, sizeof r);
    r[6] = (r[6] & 0x0f) | 0x40; r[8] = (r[8] & 0x3f) | 0x80;   // random, version 4
    snprintf(uuid, 37, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
        r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]);
}

/// Session callback, core lock held: the Mac sent this board its key by cable.
bool app_enroll(void *context, const uint8_t key[32], const char *host, const char *name) {
    (void)context;
    app_mac_t mac = { .valid = true };
    memcpy(mac.key, key, 32);
    strlcpy(mac.host, host, sizeof mac.host);
    strlcpy(mac.name, name, sizeof mac.name);
    nvs_handle_t handle;
    if (nvs_open("trackpad", NVS_READWRITE, &handle) != ESP_OK) return false;
    bool stored = nvs_set_blob(handle, "mac", &mac, sizeof mac) == ESP_OK && nvs_commit(handle) == ESP_OK;
    nvs_close(handle);
    if (stored) { g_mac = mac; g_ui_dirty = true; }
    return stored;
}

void app_forget_mac(void) {
    nvs_handle_t handle;
    if (nvs_open("trackpad", NVS_READWRITE, &handle) == ESP_OK) {
        nvs_erase_key(handle, "mac");
        nvs_commit(handle);
        nvs_close(handle);
    }
    core_lock();
    memset(&g_mac, 0, sizeof g_mac);
    g_session.enrolled = false;
    if (g_link == LINK_WIFI || g_link == LINK_BLE) tp_session_stop(&g_session, "Mac forgotten");
    g_ui_dirty = true;
    core_unlock();
}

// Bluetooth carries far fewer packets per second than a finger produces.
// While it is busy, consecutive pointer moves and scroll steps are summed
// into one command instead of queueing up as lag.
static tp_command_t held;
static bool holding;

static bool merge(tp_command_t *into, const tp_command_t *next) {
    if (into->kind != next->kind) return false;
    if (next->kind == TP_SCROLL && (into->phase != TP_CHANGED || next->phase != TP_CHANGED)) return false;
    if (next->kind != TP_MOVE && next->kind != TP_SCROLL) return false;
    double dx = into->dx + next->dx, dy = into->dy + next->dy, limit = next->kind == TP_MOVE ? 128 : 2048;
    if (dx > limit || dx < -limit || dy > limit || dy < -limit) return false;
    // A reversal stays visible as its own step.
    if (next->kind == TP_SCROLL && into->dx * next->dx + into->dy * next->dy < 0) return false;
    double interval = into->interval_ms + next->interval_ms;
    if (into->has_interval && next->has_interval && interval > 250) return false;
    into->dx = dx; into->dy = dy;
    if (into->has_interval && next->has_interval) into->interval_ms = interval;
    else into->has_interval = false;
    return true;
}

void app_flush(void) {
    core_lock();
    if (holding) { holding = false; tp_session_send(&g_session, &held, app_now_ms()); }
    core_unlock();
}

void app_send(const tp_command_t *command) {
    bool slow = g_link == LINK_BLE && ble_link_busy();
    if (holding) {
        if (slow && merge(&held, command)) return;
        holding = false;
        tp_session_send(&g_session, &held, app_now_ms());
    }
    bool mergeable = command->kind == TP_MOVE || (command->kind == TP_SCROLL && command->phase == TP_CHANGED);
    if (slow && mergeable) { held = *command; holding = true; return; }
    tp_session_send(&g_session, command, app_now_ms());
}

static bool session_write(const uint8_t *bytes, size_t length, void *context) {
    (void)context;
    return g_link == LINK_USB ? usb_link_write(bytes, length) : (g_link != LINK_NONE && secure_link_write(bytes, length));
}

static void session_changed(void *context, const char *reason) {
    (void)context;
    const char *route = g_link == LINK_WIFI ? "Wi-Fi" : (g_link == LINK_BLE ? "Bluetooth" : "USB");
    if (reason == tp_mac_resting) g_host_asleep = true;
    else if (g_session.state == TP_SESSION_CONNECTED) g_host_asleep = false;
    if (reason) { snprintf(g_status, sizeof g_status, "%s", reason); g_link = LINK_NONE; }
    else if (g_session.state == TP_SESSION_CONNECTED) { snprintf(g_status, sizeof g_status, "Connected to Mac - %s", route); app_apply_capabilities(); }
    else snprintf(g_status, sizeof g_status, "Connecting to Mac over %s...", route);
    if (g_session.state != TP_SESSION_CONNECTED) { g_dragging = false; holding = false; }
    ESP_LOGI("session", "%s", g_status);
    g_ui_dirty = true;
}

// On a computer's USB port the screen can be bright; on a battery or charger it
// starts at the lowest level. The slider in Settings changes whichever applies.
uint8_t app_brightness(void) {
    return usb_link_host_present() ? g_settings.brightness : g_settings.brightness_battery;
}

void app_set_brightness(uint8_t percent) {
    if (usb_link_host_present()) g_settings.brightness = percent; else g_settings.brightness_battery = percent;
}

/// Rough single-cell lithium curve: resting voltage to remaining charge.
static int battery_percent(float volts) {
    static const struct { float volts; int percent; } curve[] = {
        { 4.15f, 100 }, { 4.00f, 85 }, { 3.90f, 70 }, { 3.80f, 55 }, { 3.72f, 40 },
        { 3.65f, 25 }, { 3.55f, 12 }, { 3.40f, 4 }, { 3.20f, 0 },
    };
    if (volts >= curve[0].volts) return 100;
    for (size_t i = 1; i < sizeof curve / sizeof curve[0]; i++) {
        if (volts >= curve[i].volts) {
            float span = (volts - curve[i].volts) / (curve[i - 1].volts - curve[i].volts);
            return curve[i].percent + (int)(span * (float)(curve[i - 1].percent - curve[i].percent));
        }
    }
    return 0;
}

/// Picks the startup route, keeps the Wi-Fi radio on only while Wi-Fi is the
/// route, and reads the battery.
static void power_task(void *unused) {
    (void)unused;
    float smoothed = 0;
    int ticks = 0;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(500));
        core_lock();
        pick_startup_route(app_now_ms());
        bool wifi = g_route == ROUTE_WIFI && g_mac.valid && !g_paused;
        core_unlock();
        // The Wireless page needs Wi-Fi to list and join networks, whatever the route.
        wifi_link_power(wifi || g_wifi_setup);

        // Battery, every five seconds, smoothed because the reading is noisy.
        if (++ticks % 10 == 1) {
            float volts = board_battery_volts();
            smoothed = smoothed == 0 ? volts : smoothed * 0.8f + volts * 0.2f;
            int percent = smoothed < 2.5f ? -1 : battery_percent(smoothed);
            if (ticks == 1 || ticks % 120 == 1) ESP_LOGI("power", "battery reading %.2f V (%d%%)", (double)volts, percent);
            if (percent != g_battery_percent) g_ui_dirty = true;
            g_battery_percent = percent;
        }
    }
}

static void session_task(void *unused) {
    (void)unused;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(200));
        core_lock();
        usb_link_poll();
        tp_session_tick(&g_session, app_now_ms());
        core_unlock();
    }
}

static void load_settings(void) {
    esp_err_t result = nvs_flash_init();
    if (result == ESP_ERR_NVS_NO_FREE_PAGES || result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }
    nvs_handle_t handle;
    if (nvs_open("trackpad", NVS_READONLY, &handle) != ESP_OK) return;
    app_settings_t saved;
    size_t size = sizeof saved;
    if (nvs_get_blob(handle, "settings", &saved, &size) == ESP_OK && size == sizeof saved
        && saved.version == APP_SETTINGS_VERSION
        && saved.sensitivity >= 0.25 && saved.sensitivity <= 3 && saved.scroll_speed >= 0.25 && saved.scroll_speed <= 3
        && saved.brightness >= 5 && saved.brightness <= 100
        && saved.brightness_battery >= 5 && saved.brightness_battery <= 100) {
        g_settings = saved;
    }
    app_mac_t mac;
    size = sizeof mac;
    if (nvs_get_blob(handle, "mac", &mac, &size) == ESP_OK && size == sizeof mac && mac.valid) g_mac = mac;
    nvs_close(handle);
}

void app_main(void) {
    core_mutex = xSemaphoreCreateRecursiveMutex();
    tp_engine_init(&g_engine);
    load_settings();
    app_apply_capabilities();
    esp_lcd_panel_handle_t panel = board_init();

    const lvgl_port_cfg_t port = ESP_LVGL_PORT_INIT_CONFIG();
    ESP_ERROR_CHECK(lvgl_port_init(&port));
    const lvgl_port_display_cfg_t display = {
        .panel_handle = panel,
        .buffer_size = BOARD_H_RES * BOARD_V_RES,
        .double_buffer = true,
        .hres = BOARD_H_RES, .vres = BOARD_V_RES,
        .color_format = LV_COLOR_FORMAT_RGB565,
        .flags = { .buff_spiram = true, .direct_mode = true },
    };
    // Draw straight into the panel's two frame buffers and swap on vsync.
    const lvgl_port_display_rgb_cfg_t rgb = { .flags = { .bb_mode = true, .avoid_tearing = true } };
    if (!lvgl_port_add_disp_rgb(&display, &rgb)) ESP_LOGE("main", "display registration failed");

    tp_session_init(&g_session, (tp_session_callbacks_t){ session_write, session_changed, NULL, app_enroll });
    g_session.enrolled = g_mac.valid;
    snprintf(g_status, sizeof g_status, "Waiting for the Mac");
    xTaskCreate(session_task, "session", 4096, NULL, 5, NULL);
    xTaskCreate(power_task, "power", 4096, NULL, 4, NULL);

    ui_start();
    board_brightness(app_brightness());
    board_backlight(true);
    secure_link_init();
    usb_link_start();
    // Bluetooth first: its controller needs internal RAM, Wi-Fi can use PSRAM.
    ble_link_start();
    wifi_link_start();
    touch_start();
}
