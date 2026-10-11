// Reads the GT911 at its report rate and routes each finger: contacts that land
// on the button strip drive LVGL, all others feed the gesture engine.
#include "app.h"
#include "board.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

// The engine expects 1000 units per shortest surface dimension, tuned on an
// iPad whose pad is about 135 mm tall. This panel is 90 mm tall at 6.67 px/mm,
// so 1.1 units per pixel keeps the same travel per millimetre and the same
// physical tap and hold tolerances.
#define UNITS_PER_PIXEL 1.1

enum { OWNER_NONE, OWNER_PAD, OWNER_STRIP };

static void send(const tp_command_t *command, void *context) {
    (void)context;
    if (command->kind == TP_BUTTON && command->button == TP_LEFT) g_dragging = command->pressed;
    tp_session_send(&g_session, command, app_now_ms());
}

static void emit(const tp_command_t *command, void *context) {
    const double *interval = context;
    tp_command_t timed = *command;
    bool navigation = timed.kind == TP_PAGE_SWIPE || timed.kind == TP_MISSION_CONTROL;
    if (timed.kind == TP_SCROLL || navigation) {
        timed.has_sample_age = true;   // Sent as soon as it is sampled.
        timed.sample_age_ms = 0;
        if ((timed.phase == TP_BEGAN || timed.phase == TP_CHANGED) && *interval > 0 && *interval <= 250) {
            timed.has_interval = true;
            timed.interval_ms = *interval;
        }
    }
    double factor = timed.kind == TP_SCROLL
        ? g_settings.scroll_speed * (g_settings.natural_scroll ? 1 : -1) : g_settings.sensitivity;
    tp_scale(&timed, factor, send, NULL);
}

static void touch_task(void *unused) {
    (void)unused;
    uint8_t owner[256] = { 0 };
    bool present[256] = { 0 };
    tp_touches_t pad = { 0 };
    double last_sample = -1;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(5));
        board_touch_t raw[BOARD_MAX_TOUCHES];
        int count = 0;
        bool fresh = board_read_touches(raw, &count);
        double now = esp_timer_get_time() / 1e6;
        if (fresh) {
            bool seen[256] = { 0 };
            ui_pointer_t pointer = g_ui_pointer;
            pointer.pressed = false;
            pad.count = 0;
            for (int i = 0; i < count; i++) {
                uint8_t id = raw[i].id;
                seen[id] = true;
                if (!present[id]) owner[id] = g_ui_modal || raw[i].x >= PAD_WIDTH ? OWNER_STRIP : OWNER_PAD;
                if (owner[id] == OWNER_PAD) {
                    pad.items[pad.count++] = (tp_touch_t){ id, raw[i].x * UNITS_PER_PIXEL, raw[i].y * UNITS_PER_PIXEL };
                } else if (!pointer.pressed) {
                    pointer = (ui_pointer_t){ true, (int16_t)raw[i].x, (int16_t)raw[i].y };
                }
            }
            for (int id = 0; id < 256; id++) present[id] = seen[id];
            g_ui_pointer = pointer;
        }
        core_lock();
        double deadline;
        bool hold_due = tp_engine_hold_deadline(&g_engine, &deadline) && now >= deadline;
        if (fresh || hold_due) {
            double interval = last_sample < 0 ? 0 : (now - last_sample) * 1000;
            last_sample = now;
            tp_engine_update(&g_engine, &pad, now, emit, &interval);
            if (pad.count == 0) last_sample = -1;
        }
        bool pending = tp_engine_hold_deadline(&g_engine, &deadline);
        core_unlock();
        if (pending != g_hold_pending) { g_hold_pending = pending; g_ui_dirty = true; }
    }
}

void touch_start(void) {
    xTaskCreatePinnedToCore(touch_task, "touch", 6144, NULL, 10, NULL, 1);
}
