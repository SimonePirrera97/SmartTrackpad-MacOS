// The session a remembered board runs over any wireless route: TLS 1.2 with the
// board's own pre-shared key (TLS_PSK_WITH_AES_128_GCM_SHA256, the suite the
// Mac and iPad use), then a pairRequest carrying the board's proof so the Mac
// accepts it without a pairing key or approval. Wi-Fi supplies a socket,
// Bluetooth a pair of GATT characteristics; everything above that is shared.
#include "app.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/stream_buffer.h"
#include "freertos/task.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/md.h"
#include "mbedtls/ssl.h"
#include "mbedtls/ssl_ciphersuites.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "secure";
#define TLS_IDENTITY "smart-trackpad-board"
#define PROOF_PREFIX "smart-trackpad-board-proof-v1:"

static StreamBufferHandle_t outgoing;
static SemaphoreHandle_t busy;   // one wireless session at a time
static mbedtls_entropy_context entropy;
static mbedtls_ctr_drbg_context random_source;

void secure_link_init(void) {
    outgoing = xStreamBufferCreate(4096, 1);
    busy = xSemaphoreCreateMutex();
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&random_source);
    mbedtls_ctr_drbg_seed(&random_source, mbedtls_entropy_func, &entropy, NULL, 0);
}

bool secure_link_write(const uint8_t *bytes, size_t length) {
    // All or nothing: half a frame on the wire would be an invalid message.
    if (!outgoing || xStreamBufferSpacesAvailable(outgoing) < length) return false;
    return xStreamBufferSend(outgoing, bytes, length, 0) == length;
}

bool secure_link_idle(void) { return !outgoing || xStreamBufferIsEmpty(outgoing); }

static void proof_for(const app_mac_t *mac, const char *uuid, char out[65]) {
    char text[sizeof PROOF_PREFIX + 37];
    snprintf(text, sizeof text, PROOF_PREFIX "%s", uuid);
    uint8_t digest[32];
    mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), mac->key, 32, (const uint8_t *)text, strlen(text), digest);
    for (int i = 0; i < 32; i++) snprintf(out + i * 2, 3, "%02x", digest[i]);
}

bool secure_session(const app_mac_t *mac, const secure_transport_t *transport) {
    if (xSemaphoreTake(busy, 0) != pdTRUE) return false;
    static const int suites[] = { MBEDTLS_TLS_PSK_WITH_AES_128_GCM_SHA256, 0 };
    mbedtls_ssl_context tls; mbedtls_ssl_config config;
    mbedtls_ssl_init(&tls); mbedtls_ssl_config_init(&config);
    bool ready = mbedtls_ssl_config_defaults(&config, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) == 0
        && mbedtls_ssl_conf_psk(&config, mac->key, 32, (const unsigned char *)TLS_IDENTITY, strlen(TLS_IDENTITY)) == 0;
    mbedtls_ssl_conf_min_tls_version(&config, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_max_tls_version(&config, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_ciphersuites(&config, suites);
    mbedtls_ssl_conf_rng(&config, mbedtls_ctr_drbg_random, &random_source);
    ready = ready && mbedtls_ssl_setup(&tls, &config) == 0;
    mbedtls_ssl_set_bio(&tls, transport->context, transport->send, transport->receive, NULL);

    int result = MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    uint64_t deadline = app_now_ms() + 12000;
    if (ready) {
        while ((result = mbedtls_ssl_handshake(&tls)) == MBEDTLS_ERR_SSL_WANT_READ || result == MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (app_now_ms() > deadline || !transport->alive(transport->context)) { result = MBEDTLS_ERR_SSL_TIMEOUT; break; }
            transport->wait(transport->context);
        }
    }
    bool secured = result == 0;
    if (!secured) {
        // The Mac app is not running, or it has forgotten this board.
        ESP_LOGW(TAG, "TLS handshake failed: -0x%04x", (unsigned)-result);
    } else {
        ESP_LOGI(TAG, "TLS session with %s established", mac->name);
        xStreamBufferReset(outgoing);
        char uuid[37], proof[65];
        app_new_uuid(uuid);
        proof_for(mac, uuid, proof);
        core_lock();
        bool mine = g_link == LINK_NONE && !usb_link_open() && !g_paused;
        if (mine) { g_link = transport->link; tp_session_start(&g_session, uuid, "000000", proof, app_now_ms()); }
        core_unlock();

        uint8_t bytes[512];
        bool alive = mine;
        while (alive && g_link == transport->link && transport->alive(transport->context)) {
            size_t queued;
            while (alive && (queued = xStreamBufferReceive(outgoing, bytes, sizeof bytes, 0)) > 0) {
                size_t sent = 0;
                while (alive && sent < queued) {
                    int written = mbedtls_ssl_write(&tls, bytes + sent, queued - sent);
                    if (written > 0) sent += (size_t)written;
                    else if (written == MBEDTLS_ERR_SSL_WANT_WRITE || written == MBEDTLS_ERR_SSL_WANT_READ) {
                        transport->wait(transport->context);
                        alive = transport->alive(transport->context);
                    } else alive = false;
                }
            }
            int count = mbedtls_ssl_read(&tls, bytes, sizeof bytes);
            if (count > 0) {
                core_lock();
                if (g_link == transport->link) tp_session_receive(&g_session, bytes, (size_t)count, app_now_ms());
                core_unlock();
            } else if (count == MBEDTLS_ERR_SSL_WANT_READ || count == MBEDTLS_ERR_SSL_WANT_WRITE) {
                transport->wait(transport->context);
            } else alive = false;
        }
        core_lock();
        if (g_link == transport->link) tp_session_stop(&g_session, transport->lost);
        core_unlock();
        mbedtls_ssl_close_notify(&tls);
    }
    mbedtls_ssl_free(&tls); mbedtls_ssl_config_free(&config);
    xSemaphoreGive(busy);
    return secured;
}
