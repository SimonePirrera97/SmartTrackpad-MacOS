// Bluetooth LE route to the remembered Mac. The Mac companion is a GATT
// peripheral; this board is the central. TLS bytes go to the Mac as
// acknowledged writes and come back as notifications, so the session is the
// same one Wi-Fi carries (secure_link.c). Contract: apps/Shared/BluetoothTransport.swift.
#include "app.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/stream_buffer.h"
#include "freertos/idf_additions.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "mbedtls/ssl.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "ble";

// ADCA100x-7D6D-4D46-ACF4-13F29B8A67E1, least significant byte first.
#define TRACKPAD_UUID(low) BLE_UUID128_INIT(0xe1, 0x67, 0x8a, 0x9b, 0xf2, 0x13, 0xf4, 0xac, 0x46, 0x4d, 0x6d, 0x7d, low, 0x10, 0xca, 0xad)
static const ble_uuid128_t service_uuid = TRACKPAD_UUID(0x00);
static const ble_uuid128_t write_uuid = TRACKPAD_UUID(0x01);    // board -> Mac, write with response
static const ble_uuid128_t notify_uuid = TRACKPAD_UUID(0x02);   // Mac -> board, notifications

enum { IDLE, SCANNING, CONNECTING, DISCOVERING, READY };
static volatile int state = IDLE;
static volatile bool synced, write_pending;
static uint8_t own_address_type;
static uint16_t connection = BLE_HS_CONN_HANDLE_NONE, service_start, service_end, write_handle, notify_handle, cccd_handle;
static StreamBufferHandle_t incoming, outgoing;
static TaskHandle_t link_task;
static char stage[128] = "starting";

static int gap_event(struct ble_gap_event *event, void *argument);

bool ble_link_busy(void) {
    return write_pending || (outgoing && !xStreamBufferIsEmpty(outgoing)) || !secure_link_idle();
}

void ble_link_status(char *text, size_t size) {
    if (g_link == LINK_BLE) snprintf(text, size, "Bluetooth: connected");
    else snprintf(text, size, "Bluetooth: %s", stage);
}

static void drop(const char *reason) {
    ESP_LOGW(TAG, "%s", reason);
    if (connection != BLE_HS_CONN_HANDLE_NONE) ble_gap_terminate(connection, BLE_ERR_REM_USER_CONN_TERM);
    else state = IDLE;
}

// ---- Outgoing: one acknowledged write at a time ----

static int written(uint16_t handle, const struct ble_gatt_error *error, struct ble_gatt_attr *attribute, void *argument);

/// Runs on the NimBLE host task.
static void pump(void) {
    if (state != READY || write_pending) return;
    uint8_t chunk[244];
    size_t limit = (size_t)ble_att_mtu(connection) - 3;
    if (limit > sizeof chunk) limit = sizeof chunk;
    size_t length = xStreamBufferReceive(outgoing, chunk, limit, 0);
    if (length == 0) {
        // Everything reached the Mac: release any motion merged meanwhile.
        if (secure_link_idle()) app_flush();
        return;
    }
    write_pending = true;
    if (ble_gattc_write_flat(connection, write_handle, chunk, (uint16_t)length, written, NULL) != 0) {
        write_pending = false;
        drop("write refused");
    }
}

static int written(uint16_t handle, const struct ble_gatt_error *error, struct ble_gatt_attr *attribute, void *argument) {
    (void)handle; (void)attribute; (void)argument;
    write_pending = false;
    if (error->status != 0) { drop("write failed"); return 0; }
    pump();
    if (link_task) xTaskNotifyGive(link_task);
    return 0;
}

static void pump_event(struct ble_npl_event *event) { (void)event; pump(); }
static struct ble_npl_event pump_request;

// ---- TLS transport callbacks (link task) ----

static int transport_send(void *context, const unsigned char *bytes, size_t length) {
    (void)context;
    if (state != READY) return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    size_t taken = xStreamBufferSend(outgoing, bytes, length, 0);
    if (taken == 0) return MBEDTLS_ERR_SSL_WANT_WRITE;
    // GATT calls must be made from the host task.
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &pump_request);
    return (int)taken;
}

static int transport_receive(void *context, unsigned char *bytes, size_t length) {
    (void)context;
    if (state != READY) return MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY;
    size_t taken = xStreamBufferReceive(incoming, bytes, length, 0);
    return taken > 0 ? (int)taken : MBEDTLS_ERR_SSL_WANT_READ;
}

static void transport_wait(void *context) { (void)context; ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(4)); }
static bool transport_alive(void *context) { (void)context; return state == READY; }

// ---- Discovery chain: service, characteristics, notification switch ----

static int subscribed(uint16_t handle, const struct ble_gatt_error *error, struct ble_gatt_attr *attribute, void *argument) {
    (void)handle; (void)attribute; (void)argument;
    if (error->status != 0) { drop("cannot enable notifications"); return 0; }
    state = READY;
    if (link_task) xTaskNotifyGive(link_task);
    return 0;
}

static int descriptor_found(uint16_t handle, const struct ble_gatt_error *error, uint16_t characteristic,
                            const struct ble_gatt_dsc *descriptor, void *argument) {
    (void)handle; (void)characteristic; (void)argument;
    if (error->status == 0) {
        if (!cccd_handle && ble_uuid_u16(&descriptor->uuid.u) == BLE_GATT_DSC_CLT_CFG_UUID16) cccd_handle = descriptor->handle;
        return 0;
    }
    if (error->status != BLE_HS_EDONE || !cccd_handle) { drop("notification switch not found"); return 0; }
    static const uint8_t enable[2] = { 1, 0 };
    if (ble_gattc_write_flat(connection, cccd_handle, enable, sizeof enable, subscribed, NULL) != 0) drop("cannot enable notifications");
    return 0;
}

static int characteristic_found(uint16_t handle, const struct ble_gatt_error *error, const struct ble_gatt_chr *characteristic, void *argument) {
    (void)handle; (void)argument;
    if (error->status == 0) {
        if (ble_uuid_cmp(&characteristic->uuid.u, &write_uuid.u) == 0) write_handle = characteristic->val_handle;
        if (ble_uuid_cmp(&characteristic->uuid.u, &notify_uuid.u) == 0) notify_handle = characteristic->val_handle;
        return 0;
    }
    if (error->status != BLE_HS_EDONE || !write_handle || !notify_handle) { drop("trackpad characteristics not found"); return 0; }
    if (ble_gattc_disc_all_dscs(connection, notify_handle, service_end, descriptor_found, NULL) != 0) drop("descriptor discovery refused");
    return 0;
}

static int service_found(uint16_t handle, const struct ble_gatt_error *error, const struct ble_gatt_svc *service, void *argument) {
    (void)handle; (void)argument;
    if (error->status == 0) { service_start = service->start_handle; service_end = service->end_handle; return 0; }
    if (error->status != BLE_HS_EDONE || !service_start) { drop("trackpad service not found"); return 0; }
    if (ble_gattc_disc_all_chrs(connection, service_start, service_end, characteristic_found, NULL) != 0) drop("characteristic discovery refused");
    return 0;
}

static int mtu_exchanged(uint16_t handle, const struct ble_gatt_error *error, uint16_t mtu, void *argument) {
    (void)handle; (void)error; (void)mtu; (void)argument;
    if (ble_gattc_disc_svc_by_uuid(connection, &service_uuid.u, service_found, NULL) != 0) drop("service discovery refused");
    return 0;
}

// ---- GAP ----

static bool advertises_trackpad(const struct ble_gap_disc_desc *found) {
    struct ble_hs_adv_fields fields;
    if (ble_hs_adv_parse_fields(&fields, found->data, found->length_data) != 0) return false;
    for (int i = 0; i < fields.num_uuids128; i++) if (ble_uuid_cmp(&fields.uuids128[i].u, &service_uuid.u) == 0) return true;
    return false;
}

static int gap_event(struct ble_gap_event *event, void *argument) {
    (void)argument;
    switch (event->type) {
    case BLE_GAP_EVENT_DISC:
        if (state != SCANNING || !advertises_trackpad(&event->disc)) return 0;
        ble_gap_disc_cancel();
        state = CONNECTING;
        snprintf(stage, sizeof stage, "connecting");
        // 15 ms connection interval: the shortest a Mac accepts.
        static const struct ble_gap_conn_params parameters = {
            .scan_itvl = 0x0010, .scan_window = 0x0010, .itvl_min = 12, .itvl_max = 12,
            .latency = 0, .supervision_timeout = 600, .min_ce_len = 0, .max_ce_len = 0,
        };
        if (ble_gap_connect(own_address_type, &event->disc.addr, 10000, &parameters, gap_event, NULL) != 0) state = IDLE;
        return 0;
    case BLE_GAP_EVENT_DISC_COMPLETE:
        if (state == SCANNING) { state = IDLE; snprintf(stage, sizeof stage, "Mac not found nearby"); g_ui_dirty = true; }
        return 0;
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) { state = IDLE; snprintf(stage, sizeof stage, "could not connect"); return 0; }
        connection = event->connect.conn_handle;
        service_start = service_end = write_handle = notify_handle = cccd_handle = 0;
        write_pending = false;
        xStreamBufferReset(incoming); xStreamBufferReset(outgoing);
        state = DISCOVERING;
        if (ble_gattc_exchange_mtu(connection, mtu_exchanged, NULL) != 0) drop("MTU exchange refused");
        return 0;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGW(TAG, "disconnected, reason 0x%x", event->disconnect.reason);
        connection = BLE_HS_CONN_HANDLE_NONE;
        write_pending = false;
        state = IDLE;
        snprintf(stage, sizeof stage, "waiting"); g_ui_dirty = true;
        if (link_task) xTaskNotifyGive(link_task);
        return 0;
    case BLE_GAP_EVENT_NOTIFY_RX:
        if (event->notify_rx.attr_handle == notify_handle) {
            uint8_t bytes[256];
            uint16_t length = OS_MBUF_PKTLEN(event->notify_rx.om);
            if (length > sizeof bytes || os_mbuf_copydata(event->notify_rx.om, 0, length, bytes) != 0
                || xStreamBufferSend(incoming, bytes, length, 0) != length) drop("incoming data overflow");
            else if (link_task) xTaskNotifyGive(link_task);
        }
        return 0;
    default:
        return 0;
    }
}

static void on_sync(void) {
    if (ble_hs_id_infer_auto(0, &own_address_type) == 0) synced = true;
}

static void host_task(void *unused) {
    (void)unused;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

// ---- Link task ----

static void ble_task(void *unused) {
    (void)unused;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        core_lock();
        app_mac_t mac = g_mac;
        bool chosen = g_route == ROUTE_BLUETOOTH && !g_paused;
        bool free_link = g_link == LINK_NONE && !usb_link_open();
        core_unlock();
        bool wanted = synced && mac.valid && free_link && chosen;
        if (!wanted) {
            if (state == SCANNING) { ble_gap_disc_cancel(); state = IDLE; }
            if (!mac.valid) snprintf(stage, sizeof stage, "plug into the Mac once to pair");
            else if (!chosen) snprintf(stage, sizeof stage, "off");
            continue;
        }
        if (state == IDLE) {
            const struct ble_gap_disc_params scan = { .passive = 1, .filter_duplicates = 0 };
            if (ble_gap_disc(own_address_type, 6000, &scan, gap_event, NULL) == 0) {
                state = SCANNING;
                snprintf(stage, sizeof stage, "looking for %.60s", mac.name); g_ui_dirty = true;
            }
        }
        if (state != READY) continue;
        const secure_transport_t transport = {
            .link = LINK_BLE, .lost = "Bluetooth connection to the Mac lost",
            .send = transport_send, .receive = transport_receive, .wait = transport_wait, .alive = transport_alive,
        };
        bool secured = secure_session(&mac, &transport);
        if (!secured) snprintf(stage, sizeof stage, "%.30s did not accept this board", mac.name);
        if (connection != BLE_HS_CONN_HANDLE_NONE) ble_gap_terminate(connection, BLE_ERR_REM_USER_CONN_TERM);
        g_ui_dirty = true;
    }
}

void ble_link_start(void) {
    incoming = xStreamBufferCreate(4096, 1);
    outgoing = xStreamBufferCreate(4096, 1);
    ESP_LOGI(TAG, "internal RAM free before Bluetooth: %u bytes", (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    if (nimble_port_init() != ESP_OK) { ESP_LOGE(TAG, "Bluetooth unavailable"); snprintf(stage, sizeof stage, "unavailable"); return; }
    ble_hs_cfg.sync_cb = on_sync;
    // The Mac reads these standard services right after connecting.
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set("Smart Trackpad Board");
    ble_npl_event_init(&pump_request, pump_event, NULL);
    nimble_port_freertos_init(host_task);
    xTaskCreatePinnedToCoreWithCaps(ble_task, "ble-link", 12288, NULL, 6, &link_task, 0, MALLOC_CAP_SPIRAM);
}
