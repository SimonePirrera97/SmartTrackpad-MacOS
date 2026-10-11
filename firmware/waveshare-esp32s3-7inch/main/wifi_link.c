// Wi-Fi route to the remembered Mac: join the saved network, find the Mac by
// its .local name, and run the usual session inside TLS 1.2 with the board's
// own pre-shared key (TLS_PSK_WITH_AES_128_GCM_SHA256, as the iPad uses).
#include "app.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/stream_buffer.h"
#include "freertos/task.h"
#include "lwip/netdb.h"
#include "lwip/sockets.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/md.h"
#include "mbedtls/ssl.h"
#include "mbedtls/ssl_ciphersuites.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "wifi";
#define MAC_PORT "47821"
#define TLS_IDENTITY "smart-trackpad-board"
#define PROOF_PREFIX "smart-trackpad-board-proof-v1:"
#define MAX_NETWORKS 16

static volatile bool joined, configured, scanning;
static char network[33], stage[128];
static char found[MAX_NETWORKS][33];
static int found_count;
static StreamBufferHandle_t outgoing;

bool wifi_link_write(const uint8_t *bytes, size_t length) {
    return outgoing && xStreamBufferSend(outgoing, bytes, length, 0) == length;
}

void wifi_link_status(char *text, size_t size) {
    if (!configured) snprintf(text, size, "No Wi-Fi network chosen");
    else if (!joined) snprintf(text, size, "Joining %s...", network);
    else if (stage[0]) snprintf(text, size, "On %s - %s", network, stage);
    else snprintf(text, size, "Connected to %s", network);
}

// ---- Network ----

static void on_event(void *argument, esp_event_base_t base, int32_t id, void *data) {
    (void)argument; (void)data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        if (configured) esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        joined = false;
        g_ui_dirty = true;
        if (configured && !scanning) esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        joined = true;
        g_ui_dirty = true;
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_SCAN_DONE) {
        uint16_t count = MAX_NETWORKS;
        static wifi_ap_record_t records[MAX_NETWORKS];
        int kept = 0;
        if (esp_wifi_scan_get_ap_records(&count, records) == ESP_OK) {
            for (int i = 0; i < count; i++) {
                const char *name = (const char *)records[i].ssid;
                bool duplicate = name[0] == 0;
                for (int j = 0; j < kept; j++) if (strcmp(found[j], name) == 0) duplicate = true;
                if (!duplicate) strlcpy(found[kept++], name, sizeof found[0]);
            }
        }
        found_count = kept;
        scanning = false;
        g_ui_dirty = true;
        if (configured && !joined) esp_wifi_connect();
    }
}

void wifi_link_scan(void) {
    if (scanning) return;
    scanning = true;
    found_count = 0;
    // A scan cannot run while the radio keeps retrying a connection.
    if (!joined) esp_wifi_disconnect();
    if (esp_wifi_scan_start(NULL, false) != ESP_OK) scanning = false;
}

int wifi_link_networks(char names[][33], int capacity, bool *still_scanning) {
    int count = found_count < capacity ? found_count : capacity;
    for (int i = 0; i < count; i++) strlcpy(names[i], found[i], 33);
    *still_scanning = scanning;
    return count;
}

void wifi_link_join(const char *name, const char *password) {
    wifi_config_t config = { 0 };
    strlcpy((char *)config.sta.ssid, name, sizeof config.sta.ssid);
    strlcpy((char *)config.sta.password, password, sizeof config.sta.password);
    strlcpy(network, name, sizeof network);
    configured = true;
    joined = false;
    esp_wifi_disconnect();
    esp_wifi_set_config(WIFI_IF_STA, &config);   // kept in flash by the Wi-Fi driver
    esp_wifi_connect();
    g_ui_dirty = true;
}

// ---- Session over TLS ----

static int socket_send(void *context, const unsigned char *bytes, size_t length) {
    int result = send(*(int *)context, bytes, length, 0);
    if (result >= 0) return result;
    return errno == EAGAIN || errno == EWOULDBLOCK ? MBEDTLS_ERR_SSL_WANT_WRITE : MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

static int socket_receive(void *context, unsigned char *bytes, size_t length) {
    int result = recv(*(int *)context, bytes, length, 0);
    if (result > 0) return result;
    if (result == 0) return MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY;
    return errno == EAGAIN || errno == EWOULDBLOCK ? MBEDTLS_ERR_SSL_WANT_READ : MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

static int open_socket(const char *host) {
    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *address = NULL;
    int lookup = getaddrinfo(host, MAC_PORT, &hints, &address);
    if (lookup != 0 || !address) { ESP_LOGW(TAG, "cannot resolve %s (%d)", host, lookup); return -1; }
    int descriptor = socket(address->ai_family, address->ai_socktype, 0);
    if (descriptor >= 0) {
        struct timeval timeout = { .tv_sec = 4 };
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
        int on = 1;
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
        if (connect(descriptor, address->ai_addr, address->ai_addrlen) != 0) {
            ESP_LOGW(TAG, "cannot connect to %s: errno %d", host, errno);
            close(descriptor); descriptor = -1;
        }
    }
    freeaddrinfo(address);
    return descriptor;
}

static void proof_for(const app_mac_t *mac, const char *uuid, char out[65]) {
    char text[sizeof PROOF_PREFIX + 37];
    snprintf(text, sizeof text, PROOF_PREFIX "%s", uuid);
    uint8_t digest[32];
    mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), mac->key, 32, (const uint8_t *)text, strlen(text), digest);
    for (int i = 0; i < 32; i++) snprintf(out + i * 2, 3, "%02x", digest[i]);
}

/// One connection attempt and, if it succeeds, the whole session. Returns when it is over.
static void run_session(const app_mac_t *mac, mbedtls_ctr_drbg_context *random) {
    snprintf(stage, sizeof stage, "looking for %s", mac->name); g_ui_dirty = true;
    int descriptor = open_socket(mac->host);
    if (descriptor < 0) return;

    static const int suites[] = { MBEDTLS_TLS_PSK_WITH_AES_128_GCM_SHA256, 0 };
    mbedtls_ssl_context tls; mbedtls_ssl_config config;
    mbedtls_ssl_init(&tls); mbedtls_ssl_config_init(&config);
    bool ready = mbedtls_ssl_config_defaults(&config, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) == 0
        && mbedtls_ssl_conf_psk(&config, mac->key, 32, (const unsigned char *)TLS_IDENTITY, strlen(TLS_IDENTITY)) == 0;
    mbedtls_ssl_conf_min_tls_version(&config, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_max_tls_version(&config, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_ciphersuites(&config, suites);
    mbedtls_ssl_conf_rng(&config, mbedtls_ctr_drbg_random, random);
    ready = ready && mbedtls_ssl_setup(&tls, &config) == 0;
    mbedtls_ssl_set_bio(&tls, &descriptor, socket_send, socket_receive, NULL);
    int result = MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    if (ready) do { result = mbedtls_ssl_handshake(&tls); } while (result == MBEDTLS_ERR_SSL_WANT_READ || result == MBEDTLS_ERR_SSL_WANT_WRITE);
    if (result != 0) {
        // The Mac app is not running, or it has forgotten this board.
        ESP_LOGW(TAG, "TLS handshake failed: -0x%04x", (unsigned)-result);
        snprintf(stage, sizeof stage, "%s did not accept this board", mac->name); g_ui_dirty = true;
    } else {
        ESP_LOGI(TAG, "TLS session with %s established", mac->name);
        fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK);
        xStreamBufferReset(outgoing);
        char uuid[37], proof[65];
        app_new_uuid(uuid);
        proof_for(mac, uuid, proof);
        core_lock();
        bool mine = g_link == LINK_NONE && !usb_link_open() && !g_paused;
        if (mine) { g_link = LINK_WIFI; tp_session_start(&g_session, uuid, "000000", proof, app_now_ms()); }
        core_unlock();
        stage[0] = 0; g_ui_dirty = true;

        uint8_t bytes[512];
        bool alive = mine;
        while (alive && g_link == LINK_WIFI) {
            size_t queued;
            while (alive && (queued = xStreamBufferReceive(outgoing, bytes, sizeof bytes, 0)) > 0) {
                size_t sent = 0;
                while (alive && sent < queued) {
                    int written = mbedtls_ssl_write(&tls, bytes + sent, queued - sent);
                    if (written > 0) sent += (size_t)written;
                    else if (written == MBEDTLS_ERR_SSL_WANT_WRITE || written == MBEDTLS_ERR_SSL_WANT_READ) vTaskDelay(1);
                    else alive = false;
                }
            }
            int count = mbedtls_ssl_read(&tls, bytes, sizeof bytes);
            if (count > 0) {
                core_lock();
                if (g_link == LINK_WIFI) tp_session_receive(&g_session, bytes, (size_t)count, app_now_ms());
                core_unlock();
            } else if (count == MBEDTLS_ERR_SSL_WANT_READ || count == MBEDTLS_ERR_SSL_WANT_WRITE) {
                // Nothing to read: wait briefly for input to send or data to arrive.
                fd_set readable; FD_ZERO(&readable); FD_SET(descriptor, &readable);
                struct timeval wait = { .tv_usec = 3000 };
                select(descriptor + 1, &readable, NULL, NULL, &wait);
            } else alive = false;
        }
        core_lock();
        if (g_link == LINK_WIFI) tp_session_stop(&g_session, "Wi-Fi connection to the Mac lost");
        core_unlock();
        mbedtls_ssl_close_notify(&tls);
    }
    mbedtls_ssl_free(&tls); mbedtls_ssl_config_free(&config);
    close(descriptor);
}

static void wifi_task(void *unused) {
    (void)unused;
    mbedtls_entropy_context entropy; mbedtls_ctr_drbg_context random;
    mbedtls_entropy_init(&entropy); mbedtls_ctr_drbg_init(&random);
    mbedtls_ctr_drbg_seed(&random, mbedtls_entropy_func, &entropy, NULL, 0);
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(1500));
        core_lock();
        app_mac_t mac = g_mac;
        bool wanted = mac.valid && joined && !g_paused && g_link == LINK_NONE && !usb_link_open();
        bool paused = g_paused, usb = usb_link_open(); int link = g_link;
        core_unlock();
        static int logged = -1;
        int state = mac.valid | joined << 1 | paused << 2 | usb << 3 | link << 4;
        if (state != logged) { logged = state; ESP_LOGI(TAG, "paired %d, on network %d, paused %d, usb open %d, link %d", mac.valid, joined, paused, usb, link); }
        if (!mac.valid) { snprintf(stage, sizeof stage, "plug into the Mac once to pair"); continue; }
        if (wanted) run_session(&mac, &random);
    }
}

void wifi_link_start(void) {
    outgoing = xStreamBufferCreate(4096, 1);
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL);
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_event, NULL);
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    wifi_config_t saved;
    if (esp_wifi_get_config(WIFI_IF_STA, &saved) == ESP_OK && saved.sta.ssid[0]) {
        strlcpy(network, (const char *)saved.sta.ssid, sizeof network);
        configured = true;
    }
    ESP_ERROR_CHECK(esp_wifi_start());
    esp_wifi_set_ps(WIFI_PS_NONE);   // latency matters more than radio power here
    // TLS needs a deep stack; keep it off the tight internal heap.
    xTaskCreatePinnedToCore(wifi_task, "wifi-link", 12288, NULL, 6, NULL, 0);
}
