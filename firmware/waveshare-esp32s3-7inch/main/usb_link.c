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
// The board leaves the bus while it is disconnected or told to use a radio, so
// the port vanishes on the Mac and the companion stops opening it.
static bool attached = true, host_at_detach;
// The Mac opened the port while startup was trying a radio; USB becomes the
// route within half a second and the session starts then.
static bool begin_waiting;

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
// Mounted survives host suspend, unlike tud_ready(): Mac sleep must not turn
// normal cable operation into touch-only deep sleep.
bool usb_link_computer_attached(void) { return uart_link_open() || (attached ? tud_mounted() : host_at_detach); }
bool usb_link_host_present(void) { return uart_link_open() || (attached ? tud_ready() : host_at_detach); }

bool usb_link_write(const uint8_t *bytes, size_t length) {
    if (uart_link_open()) return uart_link_write(bytes, length);
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
        if (!uart_link_open() && g_link == LINK_USB) tp_session_receive(&g_session, bytes, length, app_now_ms());
        core_unlock();
    }
}

/// The Mac opened the port: start a session on it. Core lock held.
static void begin(void) {
    if (uart_link_open()) return;
    begin_waiting = port_open && attached && g_route != ROUTE_USB;
    if (!port_open || !attached || begin_waiting) return;
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
    ESP_LOGI(TAG, "Mac %s the port (link %d)", port_open ? "opened" : "closed", g_link);
    if (port_open) begin();
    else {
        begin_waiting = false;
        if (g_link == LINK_USB && !uart_link_open()) tp_session_stop(&g_session, g_paused ? "Disconnected" : "Waiting for the Mac");
    }
    core_unlock();
}

/// Joins or leaves the bus to match the route, and notices a pulled cable:
/// that sends no "port closed" message, so the open flag would stay set for
/// ever. The bus going quiet (suspended or unmounted) is the only sign. Core
/// lock held.
void usb_link_poll(void) {
    bool wanted = app_usb_wanted();
    if (wanted != attached) {
        attached = wanted;
        if (wanted) tud_connect();
        else {
            host_at_detach = tud_ready();
            port_open = false;
            if (g_link == LINK_USB) tp_session_stop(&g_session, g_paused ? "Disconnected" : "Changing route");
            tud_disconnect();
        }
        ESP_LOGI(TAG, "%s the USB bus", wanted ? "joined" : "left");
    }
    if (begin_waiting) begin();
    static bool was_ready;
    bool ready = tud_ready();
    // Three levels: "connected" needs only a bus reset from a host, so it tells
    // a dead cable (never connected) from a host that will not configure us.
    static int bus_state = -1;
    int state_now = tud_connected() | tud_mounted() << 1 | tud_suspended() << 2;
    if (state_now != bus_state) {
        bus_state = state_now;
        ESP_LOGI(TAG, "bus: host seen %d, configured %d, suspended %d", tud_connected(), tud_mounted(), tud_suspended());
    }
    if (ready != was_ready) {
        was_ready = ready;
        g_ui_dirty = true;
        ESP_LOGI(TAG, "USB bus %s", ready ? "active" : "quiet (unplugged or host asleep)");
    }
    if (uart_link_open() || !port_open || ready) return;
    port_open = false;
    if (g_link == LINK_USB) tp_session_stop(&g_session, "Waiting for the Mac");
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
