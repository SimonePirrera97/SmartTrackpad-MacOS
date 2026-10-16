#include "board.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "esp_attr.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "driver/rtc_io.h"
#include "esp_check.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_rgb.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

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
#define EXIO_BACKLIGHT 2   // DISP also feeds the backlight driver's enable
#define EXIO_LCD_RESET 3
#define EXIO_SD_CS 4
#define EXIO_USB_SELECT 5   // low = native USB on GPIO19/20, high = CAN
#define EXIO_LCD_POWER 6

#define GT911_STATUS 0x814E
#define GT911_POINTS 0x814F

static i2c_master_bus_handle_t bus;
static i2c_master_dev_handle_t exio, gt911;
static uint8_t outputs;
static SemaphoreHandle_t exio_mutex;

static bool exio_write(uint8_t reg, uint8_t value) {
    uint8_t data[2] = { reg, value };
    xSemaphoreTake(exio_mutex, portMAX_DELAY);
    esp_err_t result = i2c_master_transmit(exio, data, 2, 100);
    // This expander is a microcontroller. An ACK need not mean it has applied
    // its command yet; do not immediately replace it with a second command.
    vTaskDelay(pdMS_TO_TICKS(10));
    xSemaphoreGive(exio_mutex);
    if (result != ESP_OK) ESP_LOGE(TAG, "IO extension write failed: %s", esp_err_to_name(result));
    return result == ESP_OK;
}

static void exio_set(int pin, bool high) {
    outputs = high ? (outputs | (1 << pin)) : (outputs & ~(1 << pin));
    exio_write(EXIO_REG_OUTPUT, outputs);
}

bool board_screen(bool on, int percent) {
    // Vendor GPIO on/off path; PWM routing varies with fitted resistors.
    // Restore brightness FIRST, then enable. Never use the undocumented
    // full-duty PWM endpoint to switch off the screen.
    if (percent < 5) percent = 5;
    if (percent > 100) percent = 100;
    if (on && !exio_write(EXIO_REG_PWM, (uint8_t)((100 - percent) * 255 / 100))) return false;
    if (on) outputs |= (1 << EXIO_LCD_POWER) | (1 << EXIO_LCD_RESET);
    outputs = on ? outputs | (1 << EXIO_BACKLIGHT) : outputs & ~(1 << EXIO_BACKLIGHT);
    return exio_write(EXIO_REG_OUTPUT, outputs);
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
    // EXT1 leaves its wake pin in the RTC domain after deep sleep.
    rtc_gpio_hold_dis(PIN_TOUCH_INT);
    rtc_gpio_deinit(PIN_TOUCH_INT);
    esp_lcd_rgb_panel_config_t panel_config = {
        .clk_src = LCD_CLK_SRC_DEFAULT,
        .timings = {
            // 36 MHz / (1386 x 661) = 39.3 Hz refresh. 24 MHz (26 Hz) shimmered
            // visibly; faster clocks compete with PSRAM for bandwidth.
            .pclk_hz = 36 * 1000 * 1000, .h_res = BOARD_H_RES, .v_res = BOARD_V_RES,
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
    exio_mutex = xSemaphoreCreateMutex();
    assert(exio_mutex);
    exio_write(EXIO_REG_MODE, 0xff);   // every expander pin is an output
    // Panel disabled until the first frame is drawn; USB rather than CAN.
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
    xSemaphoreTake(exio_mutex, portMAX_DELAY);
    esp_err_t result = i2c_master_transmit_receive(exio, &reg, 1, raw, 2, 100);
    xSemaphoreGive(exio_mutex);
    if (result != ESP_OK) return 0;
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

// Called only by the touch task, with no contacts down and the session offline.
// Leave the GT911 powered: its INT pulse is the external RTC wake source.
bool board_prepare_deep_sleep(void) {
    uint8_t mode;
    // GT911 Module_Switch1 bits 1:0: rising, falling, low, high interrupt.
    if (gt911_read(0x804D, &mode, 1) != ESP_OK) return false;
    int active = (mode & 3) == 0 || (mode & 3) == 3;
    if (!board_screen(false, 0)) return false;
    // EXIO6 controls the panel analog supply; touch has its own 3.3 V supply.
    outputs &= ~((1 << EXIO_LCD_POWER) | (1 << EXIO_LCD_RESET));
    if (!exio_write(EXIO_REG_OUTPUT, outputs)) return false;

    // LCD shutdown can leave a release/noise report pending. GT911 repeats
    // interrupts until status is acknowledged. Drain zero-contact reports AFTER
    // shutting down the LCD, and require a quiet line before arming RTC wake.
    // Leave real contacts unread so the touch task can wake on them normally.
    int64_t started = esp_timer_get_time(), quiet_since = started;
    bool quiet = false;
    while (esp_timer_get_time() - started < 750000) {
        uint8_t status;
        if (gt911_read(GT911_STATUS, &status, 1) != ESP_OK) return false;
        int64_t now = esp_timer_get_time();
        if (status & 0x80) {
            if (status & 0x0f) return false;
            uint8_t clear[] = { GT911_STATUS >> 8, GT911_STATUS & 0xff, 0 };
            if (i2c_master_transmit(gt911, clear, sizeof clear, 50) != ESP_OK) return false;
            quiet_since = now;
        }
        if (gpio_get_level(PIN_TOUCH_INT) == active) quiet_since = now;
        if (now - started >= 200000 && now - quiet_since >= 100000) { quiet = true; break; }
        vTaskDelay(pdMS_TO_TICKS(5));
    }
    if (!quiet) {
        ESP_LOGW(TAG, "sleep deferred: touch interrupt not quiet");
        return false;
    }

    // Digital GPIO configuration does not configure the RTC pad. GT911 requires
    // a floating input: explicitly remove the RTC pulls before selecting EXT1.
    // Keep RTC peripherals powered so the input stays configured during sleep.
    rtc_gpio_init(PIN_TOUCH_INT);
    rtc_gpio_set_direction(PIN_TOUCH_INT, RTC_GPIO_MODE_INPUT_ONLY);
    rtc_gpio_pullup_dis(PIN_TOUCH_INT);
    rtc_gpio_pulldown_dis(PIN_TOUCH_INT);
    vTaskDelay(pdMS_TO_TICKS(5));
    if (rtc_gpio_get_level(PIN_TOUCH_INT) == active) {
        rtc_gpio_deinit(PIN_TOUCH_INT);
        return false;
    }
    esp_err_t result = esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_ON);
    if (result == ESP_OK) result = esp_sleep_enable_ext1_wakeup_io(1ULL << PIN_TOUCH_INT,
        active ? ESP_EXT1_WAKEUP_ANY_HIGH : ESP_EXT1_WAKEUP_ANY_LOW);
    if (result != ESP_OK) { rtc_gpio_deinit(PIN_TOUCH_INT); return false; }
    ESP_LOGI(TAG, "deep sleep: LCD off, touch mode %u, RTC idle %d, wake level %d", mode & 3,
             rtc_gpio_get_level(PIN_TOUCH_INT), active);
    return true;
}
