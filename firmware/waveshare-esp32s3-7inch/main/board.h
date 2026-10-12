// Waveshare ESP32-S3-Touch-LCD-7B: pins, display, IO extension chip and GT911.
// Pin and timing values come from the vendor's ESP-IDF examples
// (github.com/waveshareteam/ESP32-S3-Touch-LCD-7B, Apache-2.0).
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_lcd_types.h"

#define BOARD_H_RES 1024
#define BOARD_V_RES 600
#define BOARD_MAX_TOUCHES 5

typedef struct { uint8_t id; uint16_t x, y; } board_touch_t;

/// Powers the panel, resets the touch controller, selects USB on the shared
/// USB/CAN pins and switches the backlight on. Returns the RGB panel.
esp_lcd_panel_handle_t board_init(void);
/// True when the controller had a fresh frame; `count` may then be 0 (all lifted).
bool board_read_touches(board_touch_t touches[BOARD_MAX_TOUCHES], int *count);
void board_backlight(bool on);
/// 5...100 percent.
void board_brightness(int percent);
/// Calls `handler` (from interrupt context) whenever the touch controller signals a new frame.
void board_on_touch_interrupt(void (*handler)(void));
/// Battery voltage in volts, or 0 if it cannot be read.
float board_battery_volts(void);
