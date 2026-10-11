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
    .mission_control = true, .page_swipes = false, .pinch = true,
};
volatile bool g_ui_dirty = true, g_dragging, g_hold_pending, g_ui_modal, g_paused;
char g_status[96];
volatile ui_pointer_t g_ui_pointer;
volatile app_link_t g_link;
app_mac_t g_mac;

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
    if (g_link == LINK_WIFI) tp_session_stop(&g_session, "Mac forgotten");
    g_ui_dirty = true;
    core_unlock();
}

static bool session_write(const uint8_t *bytes, size_t length, void *context) {
    (void)context;
    return g_link == LINK_USB ? usb_link_write(bytes, length) : (g_link == LINK_WIFI && wifi_link_write(bytes, length));
}

static void session_changed(void *context, const char *reason) {
    (void)context;
    const char *route = g_link == LINK_WIFI ? "Wi-Fi" : "USB";
    if (reason) { snprintf(g_status, sizeof g_status, "%s", reason); g_link = LINK_NONE; }
    else if (g_session.state == TP_SESSION_CONNECTED) { snprintf(g_status, sizeof g_status, "Connected to Mac - %s", route); app_apply_capabilities(); }
    else snprintf(g_status, sizeof g_status, "Connecting to Mac over %s...", route);
    if (g_session.state != TP_SESSION_CONNECTED) g_dragging = false;
    ESP_LOGI("session", "%s", g_status);
    g_ui_dirty = true;
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
        && saved.sensitivity >= 0.25 && saved.sensitivity <= 3 && saved.scroll_speed >= 0.25 && saved.scroll_speed <= 3) {
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

    ui_start();
    board_backlight(true);
    usb_link_start();
    wifi_link_start();
    touch_start();
}
