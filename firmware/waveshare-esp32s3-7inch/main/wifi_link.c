// Wi-Fi route to the remembered Mac: join a saved network, find the Mac by
// its .local name and hand the socket to the shared TLS session (secure_link.c).
#include "app.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/idf_additions.h"
#include "freertos/task.h"
#include "lwip/netdb.h"
#include "lwip/sockets.h"
#include "mbedtls/ssl.h"
#include "nvs.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "wifi";
#define MAC_PORT "47821"
#define MAX_NETWORKS 16
#define MAX_SAVED 8

static volatile bool joined, configured, scanning;
static volatile bool powered;   // the radio is switched on
static char network[33], stage[128];
static char found[MAX_NETWORKS][33];
static int found_count;

// Every network the board has joined, most recent first, with its password.
typedef struct { char name[33]; char password[65]; } saved_network_t;
static saved_network_t saved[MAX_SAVED], trying;
static int saved_count;
static uint64_t join_started_ms;

static void store_saved(void) {
    nvs_handle_t handle;
    if (nvs_open("trackpad", NVS_READWRITE, &handle) != ESP_OK) return;
    nvs_set_blob(handle, "networks", saved, sizeof(saved_network_t) * (size_t)saved_count);
    nvs_commit(handle);
    nvs_close(handle);
}

static void load_saved(void) {
    nvs_handle_t handle;
    if (nvs_open("trackpad", NVS_READONLY, &handle) != ESP_OK) return;
    size_t size = sizeof saved;
    if (nvs_get_blob(handle, "networks", saved, &size) == ESP_OK) saved_count = (int)(size / sizeof(saved_network_t));
    nvs_close(handle);
}

static const saved_network_t *find_saved(const char *name) {
    for (int i = 0; i < saved_count; i++) if (strcmp(saved[i].name, name) == 0) return &saved[i];
    return NULL;
}

bool wifi_link_saved(const char *name) { return find_saved(name) != NULL; }

/// Moves a network that just worked to the front; the oldest drops off the end.
static void remember(const saved_network_t *network) {
    int index = 0;
    while (index < saved_count && strcmp(saved[index].name, network->name) != 0) index++;
    if (index == 0 && saved_count > 0 && strcmp(saved[0].password, network->password) == 0) return;
    if (index == saved_count && saved_count < MAX_SAVED) saved_count++;
    if (index >= MAX_SAVED) index = MAX_SAVED - 1;
    memmove(&saved[1], &saved[0], sizeof(saved_network_t) * (size_t)index);
    saved[0] = *network;
    store_saved();
}

static void connect_to(const saved_network_t *target) {
    wifi_config_t config = { 0 };
    strlcpy((char *)config.sta.ssid, target->name, sizeof config.sta.ssid);
    strlcpy((char *)config.sta.password, target->password, sizeof config.sta.password);
    trying = *target;
    strlcpy(network, target->name, sizeof network);
    configured = true;
    joined = false;
    join_started_ms = app_now_ms();
    esp_wifi_disconnect();
    esp_wifi_set_config(WIFI_IF_STA, &config);
    esp_wifi_connect();
    g_ui_dirty = true;
}

void wifi_link_status(char *text, size_t size) {
    if (!powered) snprintf(text, size, "off");
    else if (!configured) snprintf(text, size, "no network chosen");
    else if (!joined) snprintf(text, size, "joining %s...", network);
    else if (stage[0]) snprintf(text, size, "on %s - %s", network, stage);
    else snprintf(text, size, "on %s", network);
}

// ---- Network ----

static void on_event(void *argument, esp_event_base_t base, int32_t id, void *data) {
    (void)argument; (void)data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        if (configured) esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        joined = false;
        g_ui_dirty = true;
        // Keep trying the chosen network for a while; after that the link task
        // scans and picks whichever saved network is in range.
        if (configured && !scanning && app_now_ms() - join_started_ms < 12000) esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        joined = true;
        if (trying.name[0]) remember(&trying);
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
        // Results come strongest first: join the best network we know.
        if (!joined && app_now_ms() - join_started_ms >= 12000) {
            for (int i = 0; i < kept; i++) {
                const saved_network_t *known = find_saved(found[i]);
                if (known) { connect_to(known); break; }
            }
        }
    }
}

void wifi_link_scan(void) {
    if (scanning || !powered) return;
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

/// `password` may be NULL for a network joined before.
void wifi_link_join(const char *name, const char *password) {
    saved_network_t target = { 0 };
    const saved_network_t *known = find_saved(name);
    strlcpy(target.name, name, sizeof target.name);
    strlcpy(target.password, password ? password : (known ? known->password : ""), sizeof target.password);
    connect_to(&target);
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

static void socket_wait(void *context) {
    int descriptor = *(int *)context;
    fd_set readable; FD_ZERO(&readable); FD_SET(descriptor, &readable);
    struct timeval wait = { .tv_usec = 3000 };
    select(descriptor + 1, &readable, NULL, NULL, &wait);
}

static bool socket_alive(void *context) { (void)context; return joined; }

void wifi_link_power(bool on) {
    if (on == powered) return;
    powered = on;
    if (on) {
        join_started_ms = app_now_ms();
        esp_wifi_start();   // STA_START then connects to the last network
        esp_wifi_set_ps(WIFI_PS_MIN_MODEM);   // modem sleep: far less power, input latency unaffected
    } else {
        joined = false;
        scanning = false;
        esp_wifi_stop();
    }
    g_ui_dirty = true;
}

static void wifi_task(void *unused) {
    (void)unused;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(1500));
        core_lock();
        app_mac_t mac = g_mac;
        bool wanted = mac.valid && joined && g_route == ROUTE_WIFI && !g_paused && g_link == LINK_NONE && !usb_link_open();
        core_unlock();
        // Off the network for a while: look for any network joined before.
        if (powered && !joined && saved_count > 0 && !scanning && !g_ui_modal && app_now_ms() - join_started_ms >= 12000) wifi_link_scan();
        if (!mac.valid) { snprintf(stage, sizeof stage, "plug into the Mac once to pair"); continue; }
        if (!wanted) continue;
        snprintf(stage, sizeof stage, "looking for %s", mac.name); g_ui_dirty = true;
        int descriptor = open_socket(mac.host);
        if (descriptor < 0) continue;
        fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK);
        const secure_transport_t transport = {
            .link = LINK_WIFI, .lost = "Wi-Fi connection to the Mac lost",
            .send = socket_send, .receive = socket_receive, .wait = socket_wait, .alive = socket_alive, .context = &descriptor,
        };
        if (secure_session(&mac, &transport)) stage[0] = 0;
        else snprintf(stage, sizeof stage, "%s did not accept this board", mac.name);
        g_ui_dirty = true;
        close(descriptor);
    }
}

void wifi_link_start(void) {
    ESP_LOGI(TAG, "internal RAM free before Wi-Fi: %u bytes", (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL);
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_event, NULL);
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    load_saved();
    wifi_config_t last;
    if (esp_wifi_get_config(WIFI_IF_STA, &last) == ESP_OK && last.sta.ssid[0]) {
        // The driver keeps the last network itself; start with that one.
        strlcpy(network, (const char *)last.sta.ssid, sizeof network);
        strlcpy(trying.name, (const char *)last.sta.ssid, sizeof trying.name);
        strlcpy(trying.password, (const char *)last.sta.password, sizeof trying.password);
        configured = true;
        join_started_ms = app_now_ms();
    }
    // The radio itself is switched on by the power task while Wi-Fi is the route.
    // TLS needs a deep stack; keep it off the tight internal heap.
    xTaskCreatePinnedToCoreWithCaps(wifi_task, "wifi-link", 12288, NULL, 6, NULL, 0, MALLOC_CAP_SPIRAM);
}
