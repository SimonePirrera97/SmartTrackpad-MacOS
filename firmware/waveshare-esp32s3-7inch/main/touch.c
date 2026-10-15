// Reads the GT911 at its report rate and routes each finger: contacts that land
// on the button strip drive LVGL, all others feed the gesture engine.
#include "app.h"
#include "board.h"
#include "esp_attr.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

// After this long without a touch the backlight dims to save power; the next
// touch restores it and is handled normally.
#define DIM_AFTER_SECONDS 30
#define DIM_PERCENT 15
// After this long the backlight switches off. Battery use also enters deep sleep.
// The power button in the top bar does the same at once, and also goes offline.
#define SCREEN_OFF_AFTER_SECONDS 300

// The engine expects 1000 units per shortest surface dimension, tuned on an
// iPad whose pad is about 135 mm tall. This panel is 90 mm tall at 6.67 px/mm,
// so 1.1 units per pixel keeps the same travel per millimetre and the same
// physical tap and hold tolerances.
#define UNITS_PER_PIXEL 1.1

enum { OWNER_NONE, OWNER_PAD, OWNER_STRIP };

static void send(const tp_command_t *command, void *context) {
    (void)context;
    if (command->kind == TP_BUTTON && command->button == TP_LEFT && g_dragging != command->pressed) {
        g_dragging = command->pressed;
        g_ui_dirty = true;   // or the screen keeps saying "Dragging" after the lift
    }
    app_send(command);
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

static TaskHandle_t touch_task_handle;
static volatile uint32_t interrupts;
static portMUX_TYPE pointer_lock = portMUX_INITIALIZER_UNLOCKED;
static ui_pointer_queue_t pointer_queue;

void touch_ui_read(ui_pointer_t *pointer, bool *more) {
    portENTER_CRITICAL(&pointer_lock);
    *pointer = ui_pointer_pop(&pointer_queue);
    *more = pointer_queue.count > 0;
    portEXIT_CRITICAL(&pointer_lock);
}

static void IRAM_ATTR on_touch_interrupt(void) {
    BaseType_t woken = pdFALSE;
    interrupts++;
    vTaskNotifyGiveFromISR(touch_task_handle, &woken);
    portYIELD_FROM_ISR(woken);
}

static void touch_task(void *unused) {
    (void)unused;
    uint8_t owner[256] = { 0 };
    bool present[256] = { 0 };
    tp_touches_t pad = { 0 };
    double last_sample = -1, last_touch = esp_timer_get_time() / 1e6, last_frame = 0;
    // `down`: a finger is on the glass. `waking`: it is the touch that ended sleep.
    bool dimmed = false, dark = false, down = false, waking = app_woke_from_sleep(), host_was_asleep = false;
    double boot_touch_guard = last_touch + (waking ? 1 : 0), sleep_started = 0;
    int applied = -1;
    double last_screen_attempt = -1;
    uint32_t frames = 0, reported = 0;
    ui_pointer_t pointer = { 0 };
    for (;;) {
        // The controller raises its interrupt line for every report, so the task
        // sleeps until then. The timeouts are a safety net: short while a finger
        // is down (hold-to-drag deadlines, and a board whose interrupt line does
        // not work), long while nothing is touching.
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(down ? 5 : 40));
        board_touch_t raw[BOARD_MAX_TOUCHES];
        int count = 0;
        bool fresh = board_read_touches(raw, &count);
        double now = esp_timer_get_time() / 1e6;
        if (fresh) { last_frame = now; frames++; }
        // A finger that is down is reported about a hundred times a second. If the
        // reports stop without a "lifted" frame, the lift was lost: treat it as one,
        // or the pointer would stay in a drag for ever.
        if (!fresh && down && now - last_frame > 0.25) {
            ESP_LOGW("touch", "reports stopped with a finger down; treating it as lifted");
            fresh = true; count = 0;
        }
        if (frames - reported >= 2000) {
            reported = frames;
            ESP_LOGI("touch", "%u reports so far, %u interrupts", (unsigned)frames, (unsigned)interrupts);
        }

        // Sleep ends with a new touch, not with a finger already resting on the glass.
        bool asleep = g_asleep;
        if (fresh) {
            if (asleep && count > 0 && !down) { app_wake(); asleep = false; waking = true; }
            down = count > 0;
        }

        // A new Mac sleep/lid-close notification takes the same offline/deep-
        // sleep path as Power. Touch wake can reconnect without retriggering
        // this old notification; a new session clears g_host_asleep.
        bool host_asleep = g_host_asleep;
        if (host_asleep != host_was_asleep) {
            host_was_asleep = host_asleep;
            if (host_asleep) {
                core_lock();
                tp_engine_cancel(&g_engine, send, NULL);
                app_sleep();
                core_unlock();
                asleep = true;
                dark = true;
            }
            if (!host_asleep && !asleep) {
                last_touch = now;
                dark = false;
                dimmed = false;
            }
        }

        // Backlight: the level for the current power source, dimmed after a pause
        // and off after a long one or while asleep. Any touch restores it.
        uint8_t level = app_brightness();
        if (fresh && count > 0 && !asleep) {
            last_touch = now;
            dark = false;
            dimmed = false;
        } else if (!dark && (asleep || now - last_touch > SCREEN_OFF_AFTER_SECONDS)) {
            dark = true;
        } else if (!dimmed && now - last_touch > DIM_AFTER_SECONDS && level > DIM_PERCENT) {
            dimmed = true;
        }
        // Never mark a failed I2C write applied. Retry while idle too, and always
        // reapply brightness on wake, including after a dimmed screen went off.
        int requested = dark ? 0 : dimmed ? (level < DIM_PERCENT ? level : DIM_PERCENT) : level;
        if (requested != applied && now - last_screen_attempt >= 0.1) {
            last_screen_attempt = now;
            if (board_screen(requested > 0, requested)) {
                ESP_LOGI("screen", "backlight %d%% (idle %.1fs, board asleep %d, Mac asleep %d)",
                         requested, now - last_touch, asleep, host_asleep);
                applied = requested;
            }
        }

        // Without a Mac sleep notification, normal computer-powered USB stays
        // online. Battery/wireless idle also sleeps after five minutes.
        if (!asleep && !down && now - last_touch > SCREEN_OFF_AFTER_SECONDS && (g_route != ROUTE_USB || !usb_link_computer_attached())) {
            core_lock();
            tp_engine_cancel(&g_engine, send, NULL);
            core_unlock();
            app_sleep();
            asleep = true;
        }
        if (asleep) {
            if (sleep_started == 0) sleep_started = now;
            // Allow transport tasks to detach, and the power-button finger to lift.
            if (!down && now - sleep_started > 2 && now - last_touch > 2) app_enter_deep_sleep();
        } else sleep_started = 0;

        // Nothing reaches the pad or the buttons while asleep, and the touch that
        // wakes the board does only that, until every finger has lifted.
        if (fresh && (asleep || waking)) {
            if (count == 0 && now >= boot_touch_guard) waking = false;
            count = 0;
        }

        if (fresh) {
            bool seen[256] = { 0 };
            pointer.pressed = false;
            pad.count = 0;
            for (int i = 0; i < count; i++) {
                uint8_t id = raw[i].id;
                seen[id] = true;
                if (!present[id]) owner[id] = g_ui_modal || raw[i].x >= PAD_WIDTH || raw[i].y < BAR_HEIGHT ? OWNER_STRIP : OWNER_PAD;
                // Opening a panel must also take fingers already on the pad.
                // They stay UI-owned until lifted, even if the panel closes.
                if (g_ui_modal) owner[id] = OWNER_STRIP;
                if (owner[id] == OWNER_PAD) {
                    pad.items[pad.count++] = (tp_touch_t){ id, raw[i].x * UNITS_PER_PIXEL, raw[i].y * UNITS_PER_PIXEL };
                } else if (!pointer.pressed) {
                    pointer = (ui_pointer_t){ true, (int16_t)raw[i].x, (int16_t)raw[i].y };
                }
            }
            for (int id = 0; id < 256; id++) present[id] = seen[id];
            portENTER_CRITICAL(&pointer_lock);
            bool queued = ui_pointer_push(&pointer_queue, pointer);
            portEXIT_CRITICAL(&pointer_lock);
            if (!queued) ESP_LOGW("touch", "UI stalled: released pointer and discarded stale touches");
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
    xTaskCreatePinnedToCore(touch_task, "touch", 6144, NULL, 10, &touch_task_handle, 1);
    board_on_touch_interrupt(on_touch_interrupt);
}
