#include "board.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "esp_attr.h"
#include "esp_check.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_rgb.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "board";

#define PIN_SDA GPIO_NUM_8
#define PIN_SCL GPIO_NUM_9
#define PIN_TOUCH_INT GPIO_NUM_4

// IO extension chip (a CH32V003 running vendor firmware) at 0x24.
#define EXIO_ADDRESS 0x24
#define EXIO_REG_MODE 0x02
#define EXIO_REG_OUTPUT 0x03
#define EXIO_REG_PWM 0x05
#define EXIO_REG_ADC 0x06
#define EXIO_TOUCH_RESET 1
#define EXIO_BACKLIGHT 2
#define EXIO_LCD_RESET 3
#define EXIO_SD_CS 4
#define EXIO_USB_SELECT 5   // low = native USB on GPIO19/20, high = CAN
#define EXIO_LCD_POWER 6

#define GT911_STATUS 0x814E
#define GT911_POINTS 0x814F

static i2c_master_bus_handle_t bus;
static i2c_master_dev_handle_t exio, gt911;
static uint8_t outputs;

static void exio_write(uint8_t reg, uint8_t value) {
    uint8_t data[2] = { reg, value };
    esp_err_t result = i2c_master_transmit(exio, data, 2, 100);
    if (result != ESP_OK) ESP_LOGE(TAG, "IO extension write failed: %s", esp_err_to_name(result));
}

static void exio_set(int pin, bool high) {
    outputs = high ? (outputs | (1 << pin)) : (outputs & ~(1 << pin));
    exio_write(EXIO_REG_OUTPUT, outputs);
}

void board_backlight(bool on) { exio_set(EXIO_BACKLIGHT, on); }

/// The expander's PWM output dims the backlight driver: a higher duty is darker,
/// and the vendor code never goes above 97 percent so the panel cannot go black.
void board_brightness(int percent) {
    if (percent < 5) percent = 5;
    if (percent > 100) percent = 100;
    int duty = 100 - percent;
    if (duty > 97) duty = 97;
    exio_write(EXIO_REG_PWM, (uint8_t)(duty * 255 / 100));
}

static esp_err_t gt911_read(uint16_t reg, uint8_t *data, size_t length) {
    uint8_t address[2] = { reg >> 8, reg & 0xff };
    return i2c_master_transmit_receive(gt911, address, 2, data, length, 50);
}

static i2c_master_dev_handle_t add_device(uint8_t address) {
    i2c_device_config_t config = { .dev_addr_length = I2C_ADDR_BIT_LEN_7, .device_address = address, .scl_speed_hz = 400000 };
    i2c_master_dev_handle_t device = NULL;
    ESP_ERROR_CHECK(i2c_master_bus_add_device(bus, &config, &device));
    return device;
}

esp_lcd_panel_handle_t board_init(void) {
    esp_lcd_rgb_panel_config_t panel_config = {
        .clk_src = LCD_CLK_SRC_DEFAULT,
        .timings = {
            .pclk_hz = 24 * 1000 * 1000, .h_res = BOARD_H_RES, .v_res = BOARD_V_RES,
            .hsync_pulse_width = 162, .hsync_back_porch = 152, .hsync_front_porch = 48,
            .vsync_pulse_width = 45, .vsync_back_porch = 13, .vsync_front_porch = 3,
            .flags = { .pclk_active_neg = 1 },
        },
        .data_width = 16, .bits_per_pixel = 16,
        .num_fbs = 2,
        // Two bounce buffers of this size come out of internal RAM, which the
        // radios also need: 10 lines (41 KB) instead of the vendor's 20.
        .bounce_buffer_size_px = BOARD_H_RES * 10,
        .hsync_gpio_num = GPIO_NUM_46, .vsync_gpio_num = GPIO_NUM_3, .de_gpio_num = GPIO_NUM_5,
        .pclk_gpio_num = GPIO_NUM_7, .disp_gpio_num = -1,
        // B3–B7, G2–G7, R3–R7.
        .data_gpio_nums = { 14, 38, 18, 17, 10, 39, 0, 45, 48, 47, 21, 1, 2, 42, 41, 40 },
        .flags = { .fb_in_psram = 1 },
    };
    esp_lcd_panel_handle_t panel = NULL;
    ESP_ERROR_CHECK(esp_lcd_new_rgb_panel(&panel_config, &panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel));

    i2c_master_bus_config_t bus_config = {
        .i2c_port = I2C_NUM_0, .sda_io_num = PIN_SDA, .scl_io_num = PIN_SCL,
        .clk_source = I2C_CLK_SRC_DEFAULT, .glitch_ignore_cnt = 7, .flags.enable_internal_pullup = true,
    };
    ESP_ERROR_CHECK(i2c_new_master_bus(&bus_config, &bus));
    exio = add_device(EXIO_ADDRESS);
    exio_write(EXIO_REG_MODE, 0xff);   // every expander pin is an output
    // Backlight off until the first frame is drawn; USB rather than CAN.
    outputs = (uint8_t)(0xff & ~(1 << EXIO_BACKLIGHT) & ~(1 << EXIO_USB_SELECT));
    exio_write(EXIO_REG_OUTPUT, outputs);

    // GT911 reset with INT held low selects I2C address 0x5D.
    gpio_config_t interrupt = { .pin_bit_mask = 1ULL << PIN_TOUCH_INT, .mode = GPIO_MODE_OUTPUT };
    gpio_config(&interrupt);
    gpio_set_level(PIN_TOUCH_INT, 0);
    exio_set(EXIO_TOUCH_RESET, false);
    vTaskDelay(pdMS_TO_TICKS(100));
    exio_set(EXIO_TOUCH_RESET, true);
    vTaskDelay(pdMS_TO_TICKS(200));
    interrupt.mode = GPIO_MODE_INPUT;
    gpio_config(&interrupt);

    uint8_t status;
    gt911 = add_device(0x5D);
    if (gt911_read(GT911_STATUS, &status, 1) != ESP_OK) {
        i2c_master_bus_rm_device(gt911);
        gt911 = add_device(0x14);
        if (gt911_read(GT911_STATUS, &status, 1) != ESP_OK) ESP_LOGE(TAG, "GT911 touch controller not found");
    }
    return panel;
}

static void (*touch_handler)(void);
static void IRAM_ATTR touch_isr(void *argument) { (void)argument; if (touch_handler) touch_handler(); }

void board_on_touch_interrupt(void (*handler)(void)) {
    touch_handler = handler;
    // The GT911 pulses INT once per report; either edge will do.
    gpio_set_intr_type(PIN_TOUCH_INT, GPIO_INTR_ANYEDGE);
    gpio_install_isr_service(0);
    gpio_isr_handler_add(PIN_TOUCH_INT, touch_isr, NULL);
}

/// The expander measures the cell through a 3:1 divider with a 10-bit converter
/// referenced to 3.3 V (figures from the vendor example).
float board_battery_volts(void) {
    uint8_t reg = EXIO_REG_ADC, raw[2];
    if (i2c_master_transmit_receive(exio, &reg, 1, raw, 2, 100) != ESP_OK) return 0;
    return (float)(raw[0] | raw[1] << 8) * 3.0f * 3.3f / 1023.0f;
}

bool board_read_touches(board_touch_t touches[BOARD_MAX_TOUCHES], int *count) {
    uint8_t status;
    if (gt911_read(GT911_STATUS, &status, 1) != ESP_OK || !(status & 0x80)) return false;
    int reported = status & 0x0f;
    if (reported > BOARD_MAX_TOUCHES) reported = BOARD_MAX_TOUCHES;
    uint8_t raw[8 * BOARD_MAX_TOUCHES];
    bool ok = reported == 0 || gt911_read(GT911_POINTS, raw, (size_t)reported * 8) == ESP_OK;
    uint8_t clear[3] = { GT911_STATUS >> 8, GT911_STATUS & 0xff, 0 };
    i2c_master_transmit(gt911, clear, 3, 50);
    if (!ok) return false;
    for (int i = 0; i < reported; i++) {
        const uint8_t *p = raw + i * 8;
        touches[i] = (board_touch_t){ .id = p[0], .x = (uint16_t)(p[1] | p[2] << 8), .y = (uint16_t)(p[3] | p[4] << 8) };
    }
    *count = reported;
    return true;
}
