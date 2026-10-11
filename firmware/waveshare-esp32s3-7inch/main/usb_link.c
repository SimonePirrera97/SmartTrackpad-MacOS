// Native USB port as a CDC serial device carrying the direct session byte
// stream. The Mac companion opens the port; DTR going high starts a session.
#include "app.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "tinyusb.h"
#include "tusb_cdc_acm.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "usb";
static bool port_open;   // the Mac has the serial port open (DTR)

// macOS names the port /dev/cu.usbmodem<serial><interface>, which is how the
// companion recognises this board without asking the user to pick a port.
static const char *strings[] = {
    (const char[]){ 0x09, 0x04 },   // English
    "Smart Trackpad",               // manufacturer
    "Smart Trackpad Board",         // product
    "SmartTrackpad",                // serial
    "Smart Trackpad session",       // CDC interface
};

static const tusb_desc_device_t device = {
    .bLength = sizeof(tusb_desc_device_t), .bDescriptorType = TUSB_DESC_DEVICE, .bcdUSB = 0x0200,
    .bDeviceClass = TUSB_CLASS_MISC, .bDeviceSubClass = MISC_SUBCLASS_COMMON, .bDeviceProtocol = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor = 0x303A, .idProduct = 0x4001,   // Espressif's vendor ID, TinyUSB CDC product
    .bcdDevice = 0x0100, .iManufacturer = 1, .iProduct = 2, .iSerialNumber = 3, .bNumConfigurations = 1,
};

bool usb_link_open(void) { return port_open; }

bool usb_link_write(const uint8_t *bytes, size_t length) {
    if (tinyusb_cdcacm_write_queue(TINYUSB_CDC_ACM_0, bytes, length) != length) return false;
    tinyusb_cdcacm_write_flush(TINYUSB_CDC_ACM_0, 0);
    return true;
}

static void received(int port, cdcacm_event_t *event) {
    (void)event;
    uint8_t bytes[256];
    size_t length = 0;
    while (tinyusb_cdcacm_read(port, bytes, sizeof bytes, &length) == ESP_OK && length > 0) {
        core_lock();
        tp_session_receive(&g_session, bytes, length, app_now_ms());
        core_unlock();
    }
}

void usb_link_begin(void) {
    if (!port_open || g_paused) return;
    // The cable outranks Wi-Fi: take the session over.
    if (g_link == LINK_WIFI) tp_session_stop(&g_session, "Switching to USB");
    if (g_session.state != TP_SESSION_IDLE) return;
    char uuid[37];
    app_new_uuid(uuid);
    g_link = LINK_USB;
    tp_session_start(&g_session, uuid, NULL, NULL, app_now_ms());
}

static void line_state(int port, cdcacm_event_t *event) {
    (void)port;
    core_lock();
    port_open = event->line_state_changed_data.dtr;
    if (port_open) usb_link_begin();
    else if (g_link == LINK_USB) tp_session_stop(&g_session, g_paused ? "Disconnected" : "Waiting for the Mac");
    core_unlock();
}

/// Pulling the cable sends no "port closed" message, so the open flag would
/// stay set for ever and keep Wi-Fi from taking over. The bus going quiet
/// (suspended or unmounted) is the only sign. Core lock held.
void usb_link_poll(void) {
    if (!port_open || tud_ready()) return;
    port_open = false;
    if (g_link == LINK_USB) tp_session_stop(&g_session, "Waiting for the Mac");
}

void usb_link_set_paused(bool paused) {
    core_lock();
    g_paused = paused;
    // Leaving the bus makes the port vanish on the Mac, so the companion stops
    // opening it and stays free for an iPad. Rejoining brings it straight back.
    if (paused) {
        tp_session_stop(&g_session, "Disconnected");
        snprintf(g_status, sizeof g_status, "Disconnected");
        port_open = false;
        tud_disconnect();
    } else {
        snprintf(g_status, sizeof g_status, "Waiting for the Mac");
        tud_connect();
    }
    g_ui_dirty = true;
    core_unlock();
}

void usb_link_start(void) {
    const tinyusb_config_t config = {
        .device_descriptor = &device,
        .string_descriptor = strings,
        .string_descriptor_count = sizeof strings / sizeof strings[0],
        .external_phy = false,
    };
    ESP_ERROR_CHECK(tinyusb_driver_install(&config));
    const tinyusb_config_cdcacm_t cdc = {
        .usb_dev = TINYUSB_USBDEV_0, .cdc_port = TINYUSB_CDC_ACM_0, .rx_unread_buf_sz = 512,
        .callback_rx = received, .callback_line_state_changed = line_state,
    };
    ESP_ERROR_CHECK(tusb_cdc_acm_init(&cdc));
    ESP_LOGI(TAG, "USB session port ready");
}
