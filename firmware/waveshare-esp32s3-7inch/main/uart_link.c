// CH343 USB-to-UART cable: charge and carry the same direct session as native USB.
// Boot output is discarded by the Mac until this adapter answers its probe.
#include "app.h"
#include "driver/uart.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <stdarg.h>
#include <string.h>

static bool opened;
static const char probe[] = "STPAD-UART/1?\n";
static const char ready[] = "STPAD-UART/1!\n";

static int discard_log(const char *format, va_list args) {
    (void)format; (void)args;
    return 0;
}

bool uart_link_open(void) { return opened; }

bool uart_link_write(const uint8_t *bytes, size_t length) {
    return opened && uart_write_bytes(UART_NUM_0, bytes, length) == (int)length;
}

static void receive_task(void *unused) {
    (void)unused;
    size_t matched = 0;
    uint8_t bytes[256];
    for (;;) {
        int count = uart_read_bytes(UART_NUM_0, bytes, sizeof bytes, pdMS_TO_TICKS(20));
        core_lock();
        if (opened && (g_paused || g_route != ROUTE_USB || g_session.state == TP_SESSION_IDLE)) opened = false;
        if (opened) {
            if (count > 0) tp_session_receive(&g_session, bytes, count, app_now_ms());
        } else {
            for (int i = 0; i < count; i++) {
                matched = bytes[i] == probe[matched] ? matched + 1 : (bytes[i] == probe[0] ? 1 : 0);
                if (matched != sizeof probe - 1) continue;
                matched = 0;
                if (!app_usb_wanted() || g_link != LINK_NONE) continue;
                app_set_route(ROUTE_USB);
                opened = true;
                uart_write_bytes(UART_NUM_0, ready, sizeof ready - 1);
                g_link = LINK_USB;
                char uuid[37];
                app_new_uuid(uuid);
                tp_session_start(&g_session, uuid, NULL, NULL, app_now_ms());
                break;
            }
        }
        core_unlock();
    }
}

void uart_link_start(void) {
    // Runtime logs cannot share an unframed session stream. ROM/boot logs remain
    // available at 115200; the application changes to 230400 and owns UART0.
    esp_log_set_vprintf(discard_log);
    uart_wait_tx_done(UART_NUM_0, pdMS_TO_TICKS(100));
    const uart_config_t config = {
        .baud_rate = 230400, .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE, .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE, .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_ERROR_CHECK(uart_param_config(UART_NUM_0, &config));
    ESP_ERROR_CHECK(uart_set_pin(UART_NUM_0, 43, 44, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0, 4096, 4096, 0, NULL, 0));
    xTaskCreate(receive_task, "uart_link", 4096, NULL, 5, NULL);
}
