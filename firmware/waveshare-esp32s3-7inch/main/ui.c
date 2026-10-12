// Screen layout: a row of connection buttons across the top, the trackpad
// surface below it on the left, and on the right a one-finger-scrollable strip
// of buttons that follows the Mac's front app.
#include "app.h"
#include "board.h"
#include "esp_lvgl_port.h"
#include <string.h>

enum { BUTTON_ACTION = 1, BUTTON_APP, BUTTON_DESKTOP };
#define BUTTON_ID(kind, value) ((void *)(uintptr_t)((kind) << 8 | (value)))

static lv_obj_t *title, *hint, *status, *strip_title, *strip, *settings_panel;
static lv_obj_t *connect_button, *route_button, *route_menu;
static int shown_bar = -1;
static lv_obj_t *wireless_panel, *battery_label;
static int shown_battery = -2;
static bool shown_on_usb;
static void refresh_wireless(void);
static bool shown_connected;
static int shown_app = -1;
static uint32_t shown_capabilities;

static void forward(const tp_command_t *command, void *context) {
    (void)context;
    app_send(command);
}

static void pressed(lv_event_t *event) {
    uintptr_t id = (uintptr_t)lv_event_get_user_data(event);
    tp_command_t command = { 0 };
    core_lock();
    switch (id >> 8) {
    case BUTTON_ACTION: command.kind = TP_ACTION; command.action = (tp_action_t)(id & 0xff); break;
    case BUTTON_DESKTOP: command.kind = TP_SHOW_DESKTOP; break;
    default:
        command.kind = TP_APP_CONTROL;
        command.app = g_session.app;
        command.app_action = (tp_app_action_t)(id & 0xff);
        memcpy(command.token, g_session.app_token, 16);
    }
    // A button never fires while a drag, scroll or pinch is still held.
    tp_engine_cancel(&g_engine, forward, NULL);
    g_dragging = false;
    forward(&command, NULL);
    core_unlock();
}

static lv_obj_t *row(int height) {
    lv_obj_t *line = lv_obj_create(strip);
    lv_obj_remove_style_all(line);
    lv_obj_set_size(line, lv_pct(100), height);
    lv_obj_set_flex_flow(line, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(line, 8, 0);
    lv_obj_remove_flag(line, LV_OBJ_FLAG_SCROLLABLE);
    return line;
}

static lv_obj_t *styled_button(lv_obj_t *parent, const char *symbol, const char *text, lv_event_cb_t action, void *id, bool enabled) {
    lv_obj_t *item = lv_button_create(parent);
    lv_obj_set_height(item, lv_pct(100));
    lv_obj_set_flex_grow(item, 1);
    lv_obj_set_style_radius(item, 18, 0);
    lv_obj_set_style_bg_color(item, lv_color_hex(0x1f3a5f), 0);
    lv_obj_set_style_bg_color(item, lv_color_hex(0x2f6fbd), LV_STATE_PRESSED);
    lv_obj_set_style_shadow_width(item, 0, 0);
    lv_obj_set_flex_flow(item, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(item, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(item, 8, 0);
    lv_obj_set_style_pad_hor(item, 4, 0);
    lv_obj_add_event_cb(item, action, LV_EVENT_CLICKED, id);
    if (!enabled) lv_obj_add_state(item, LV_STATE_DISABLED);
    lv_obj_t *icon = lv_label_create(item);
    lv_label_set_text(icon, symbol);
    lv_obj_set_style_text_font(icon, &lv_font_montserrat_28, 0);
    lv_obj_t *label = lv_label_create(item);
    lv_label_set_text(label, text);
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(label, lv_pct(100));
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_16, 0);
    return label;
}

static void button(lv_obj_t *parent, const char *symbol, const char *text, void *id, bool enabled) {
    styled_button(parent, symbol, text, pressed, id, enabled);
}

static const char *app_symbol(tp_app_action_t action) {
    switch (action) {
    case TP_SAVE: return LV_SYMBOL_SAVE;
    case TP_COMPILE: return LV_SYMBOL_SETTINGS;
    case TP_DELETE: case TP_DELETE_WORD: return LV_SYMBOL_BACKSPACE;
    case TP_ENTER: return LV_SYMBOL_NEW_LINE;
    case TP_NEW_TAB: return LV_SYMBOL_PLUS;
    case TP_CLOSE_TAB: return LV_SYMBOL_CLOSE;
    case TP_PLAY_PAUSE: return LV_SYMBOL_PLAY;
    case TP_PREVIOUS_TRACK: return LV_SYMBOL_PREV;
    case TP_NEXT_TRACK: return LV_SYMBOL_NEXT;
    case TP_VOLUME_DOWN: return LV_SYMBOL_VOLUME_MID;
    case TP_VOLUME_UP: return LV_SYMBOL_VOLUME_MAX;
    case TP_NEW_FOLDER: return LV_SYMBOL_DIRECTORY;
    default: return LV_SYMBOL_TRASH;
    }
}

static void app_button(lv_obj_t *parent, tp_app_action_t action, bool enabled) {
    button(parent, app_symbol(action), tp_app_action_labels[action], BUTTON_ID(BUTTON_APP, action), enabled);
}

/// Same button order as the iPad's EditingActionStrip.
static void rebuild_strip(bool connected, bool has_app, tp_app_t app, uint32_t capabilities) {
    bool actions = connected && (capabilities & TP_CAP_STANDARD_ACTIONS);
    bool controls = connected && has_app && (capabilities & TP_CAP_APP_CONTROLS);
    if (!controls) app = TP_APP_OTHER;
    lv_label_set_text(strip_title, tp_app_titles[app]);
    lv_obj_clean(strip);
    lv_obj_scroll_to_y(strip, 0, LV_ANIM_OFF);
    const int tall = 122, low = 100;
    if (app == TP_APP_SPOTIFY) {
        lv_obj_t *tracks = row(tall);
        app_button(tracks, TP_PREVIOUS_TRACK, true); app_button(tracks, TP_NEXT_TRACK, true);
        app_button(row(low), TP_PLAY_PAUSE, true);
        lv_obj_t *volume = row(tall);
        app_button(volume, TP_VOLUME_DOWN, true); app_button(volume, TP_VOLUME_UP, true);
    } else {
        lv_obj_t *top = row(tall);
        button(top, LV_SYMBOL_COPY, "Copy", BUTTON_ID(BUTTON_ACTION, TP_COPY), actions);
        button(top, LV_SYMBOL_CUT, "Cut", BUTTON_ID(BUTTON_ACTION, TP_CUT), actions);
        button(row(tall), LV_SYMBOL_PASTE, "Paste", BUTTON_ID(BUTTON_ACTION, TP_PASTE), actions);
        if (app == TP_APP_SAFARI) {
            lv_obj_t *tabs = row(low);
            app_button(tabs, TP_NEW_TAB, true); app_button(tabs, TP_CLOSE_TAB, true);
        }
        lv_obj_t *pair = row(low);
        if (app == TP_APP_TERMINAL) { app_button(pair, TP_DELETE_WORD, true); app_button(pair, TP_ENTER, true); }
        else if (app == TP_APP_FINDER) { app_button(pair, TP_NEW_FOLDER, true); app_button(pair, TP_TRASH, true); }
        else {
            button(pair, LV_SYMBOL_LEFT, "Undo", BUTTON_ID(BUTTON_ACTION, TP_UNDO), actions);
            button(pair, LV_SYMBOL_RIGHT, "Redo", BUTTON_ID(BUTTON_ACTION, TP_REDO), actions);
        }
        if (app == TP_APP_VSCODE) {
            app_button(row(low), TP_SAVE, true); app_button(row(low), TP_COMPILE, true); app_button(row(low), TP_DELETE, true);
        } else if (app == TP_APP_SAFARI) {
            app_button(row(low), TP_SAVE, true);
        }
    }
    lv_obj_t *last = row(low);
    button(last, LV_SYMBOL_HOME, "Show Desktop", BUTTON_ID(BUTTON_DESKTOP, 0),
           connected && (capabilities & TP_CAP_SHOW_DESKTOP));
    button(last, LV_SYMBOL_POWER, "Quit App", BUTTON_ID(BUTTON_ACTION, TP_QUIT), actions);
}

/// Runs in the LVGL task. Copies what it needs under the core lock, then draws.
static void refresh(lv_timer_t *timer) {
    (void)timer;
    if (!g_ui_dirty) return;
    g_ui_dirty = false;
    if (wireless_panel) refresh_wireless();
    core_lock();
    bool connected = g_session.state == TP_SESSION_CONNECTED;
    bool has_app = g_session.has_app;
    tp_app_t app = g_session.app;
    uint32_t capabilities = g_session.capabilities;
    char text[sizeof g_status];
    strlcpy(text, g_status, sizeof text);
    core_unlock();

    // Only worth reading while there is no session: "Connected" is in the top bar.
    lv_label_set_text(status, connected ? "" : text);
    core_lock();
    app_route_t route = g_route;
    bool paired = g_mac.valid, paused = g_paused;
    core_unlock();
    bool on_usb = usb_link_host_present();
    if (!connected) {
        lv_label_set_text(title, paused ? "Disconnected" : "Connect to your Mac");
        lv_label_set_text(hint, paused ? "Tap Disconnected to go back online."
            : (route == ROUTE_WIFI || route == ROUTE_BLUETOOTH) && !paired
            ? "Wi-Fi and Bluetooth need pairing first: connect by USB once\nand click \"Remember this board\" in the Mac app."
            : "Plug the port marked USB into your Mac\nand open Smart Trackpad Companion.");
    } else {
        // The built-in font has no middle dot or ellipsis glyphs.
        lv_label_set_text(title, g_dragging ? "Dragging - lift to release"
                          : (g_hold_pending ? "Hold still to drag..." : "Slide to move - tap to click"));
        lv_label_set_text(hint, "Two fingers to scroll or right-click - hold to drag");
    }
    // Battery cell: charge when a cell is measured, otherwise what powers the board.
    int battery = g_battery_percent;
    if (battery != shown_battery || on_usb != shown_on_usb) {
        shown_battery = battery; shown_on_usb = on_usb;
        if (battery < 0) lv_label_set_text(battery_label, on_usb ? LV_SYMBOL_USB "  USB power" : LV_SYMBOL_CHARGE "  No battery");
        else {
            const char *icon = battery > 80 ? LV_SYMBOL_BATTERY_FULL : battery > 55 ? LV_SYMBOL_BATTERY_3
                : battery > 30 ? LV_SYMBOL_BATTERY_2 : battery > 10 ? LV_SYMBOL_BATTERY_1 : LV_SYMBOL_BATTERY_EMPTY;
            lv_label_set_text_fmt(battery_label, "%s  %d%%%s", icon, battery, on_usb ? "  " LV_SYMBOL_USB : "");
        }
    }
    // Top bar: connection state, and the route, which is also the menu to change it.
    int state = paused ? 0 : connected ? 2 : 1;
    int bar = state | route << 2;
    if (bar != shown_bar) {
        shown_bar = bar;
        static const char *const states[] = { LV_SYMBOL_CLOSE "  Disconnected", LV_SYMBOL_REFRESH "  Connecting", LV_SYMBOL_OK "  Connected" };
        static const uint32_t state_colors[] = { 0x2a2f37, 0x6b5416, 0x1f6b3a };
        static const char *const routes[] = { LV_SYMBOL_USB "  USB", LV_SYMBOL_WIFI "  Wi-Fi", LV_SYMBOL_BLUETOOTH "  Bluetooth" };
        lv_label_set_text(lv_obj_get_child(connect_button, 0), states[state]);
        lv_obj_set_style_bg_color(connect_button, lv_color_hex(state_colors[state]), 0);
        lv_label_set_text(lv_obj_get_child(route_button, 0), routes[route]);
    }
    int shown = connected && has_app ? (int)app : -1;
    if (connected != shown_connected || shown != shown_app || capabilities != shown_capabilities) {
        shown_connected = connected; shown_app = shown; shown_capabilities = capabilities;
        rebuild_strip(connected, has_app, app, capabilities);
    }
}

// ---- Settings ----

enum { SET_NATURAL, SET_TAP, SET_TWO_FINGER, SET_HOLD, SET_THREE_DRAG, SET_MISSION, SET_PAGES, SET_PINCH, SET_COUNT };
static lv_obj_t *switches[SET_COUNT], *speed_value[3];
static app_settings_t settings_at_open;

static bool *setting(int id) {
    switch (id) {
    case SET_NATURAL: return &g_settings.natural_scroll;
    case SET_TAP: return &g_settings.tap_to_click;
    case SET_TWO_FINGER: return &g_settings.two_finger_tap;
    case SET_HOLD: return &g_settings.hold_to_drag;
    case SET_THREE_DRAG: return &g_settings.three_finger_drag;
    case SET_MISSION: return &g_settings.mission_control;
    case SET_PAGES: return &g_settings.page_swipes;
    default: return &g_settings.pinch;
    }
}

static void show_switches(void) {
    for (int id = 0; id < SET_COUNT; id++) {
        if (*setting(id)) lv_obj_add_state(switches[id], LV_STATE_CHECKED);
        else lv_obj_remove_state(switches[id], LV_STATE_CHECKED);
    }
}

static void toggled(lv_event_t *event) {
    int id = (int)(uintptr_t)lv_event_get_user_data(event);
    bool on = lv_obj_has_state(lv_event_get_target(event), LV_STATE_CHECKED);
    core_lock();
    *setting(id) = on;
    // Three fingers either drag or swipe pages, never both. Mission Control
    // uses four fingers and is independent.
    if (on && id == SET_THREE_DRAG) g_settings.page_swipes = false;
    if (on && id == SET_PAGES) g_settings.three_finger_drag = false;
    tp_engine_cancel(&g_engine, forward, NULL);
    app_apply_capabilities();
    core_unlock();
    show_switches();
}

static void speed_changed(lv_event_t *event) {
    int which = (int)(uintptr_t)lv_event_get_user_data(event);
    int value = lv_slider_get_value(lv_event_get_target(event));
    core_lock();
    if (which == 0) g_settings.sensitivity = value / 100.0;
    else if (which == 1) g_settings.scroll_speed = value / 100.0;
    else app_set_brightness((uint8_t)value);   // the touch task applies it
    core_unlock();
    if (which == 2) lv_label_set_text_fmt(speed_value[which], "%d%%", value);
    else lv_label_set_text_fmt(speed_value[which], "%d.%02dx", value / 100, value % 100);
}

static lv_obj_t *settings_row(lv_obj_t *parent, const char *text) {
    lv_obj_t *line = lv_obj_create(parent);
    lv_obj_remove_style_all(line);
    lv_obj_set_width(line, lv_pct(100));
    lv_obj_set_flex_grow(line, 1);   // rows share the column's height evenly
    lv_obj_set_flex_flow(line, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(line, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_remove_flag(line, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_t *label = lv_label_create(line);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_24, 0);
    return line;
}

static void add_switch(lv_obj_t *parent, const char *text, int id) {
    lv_obj_t *control = lv_switch_create(settings_row(parent, text));
    lv_obj_set_size(control, 96, 50);
    lv_obj_add_event_cb(control, toggled, LV_EVENT_VALUE_CHANGED, (void *)(uintptr_t)id);
    switches[id] = control;
}

static void add_speed(lv_obj_t *parent, const char *text, int which, double value) {
    lv_obj_t *line = settings_row(parent, text);
    lv_obj_t *slider = lv_slider_create(line);
    lv_obj_set_size(slider, 190, 18);
    if (which == 2) lv_slider_set_range(slider, 10, 100); else lv_slider_set_range(slider, 25, 300);
    lv_slider_set_value(slider, which == 2 ? (int)value : (int)(value * 100 + 0.5), LV_ANIM_OFF);
    lv_obj_set_ext_click_area(slider, 22);
    lv_obj_add_event_cb(slider, speed_changed, LV_EVENT_VALUE_CHANGED, (void *)(uintptr_t)which);
    speed_value[which] = lv_label_create(line);
    lv_obj_set_width(speed_value[which], 76);
    lv_obj_set_style_text_font(speed_value[which], &lv_font_montserrat_20, 0);
    int shown = (int)(value * 100 + 0.5);
    if (which == 2) lv_label_set_text_fmt(speed_value[which], "%d%%", (int)value);
    else lv_label_set_text_fmt(speed_value[which], "%d.%02dx", shown / 100, shown % 100);
}

// ---- Wireless: Wi-Fi network and the remembered Mac ----

static lv_obj_t *wireless_status, *mac_status, *network_list, *password_row, *password_field, *keyboard, *forget_button;
static char chosen_network[33];
static int listed_networks = -1;

static void close_wireless(lv_event_t *event) {
    (void)event;
    lv_obj_delete_async(wireless_panel);
    wireless_panel = NULL;
    listed_networks = -1;
    g_ui_modal = false;
    g_wifi_setup = false;
    g_ui_dirty = true;
}

static void rescan(lv_event_t *event) {
    (void)event;
    listed_networks = -1;
    wifi_link_scan();
    g_ui_dirty = true;
}

static void join_network(lv_event_t *event) {
    (void)event;
    wifi_link_join(chosen_network, lv_textarea_get_text(password_field));
    lv_obj_add_flag(password_row, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(keyboard, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(network_list, LV_OBJ_FLAG_HIDDEN);
}

static void network_chosen(lv_event_t *event) {
    strlcpy(chosen_network, lv_list_get_button_text(network_list, lv_event_get_target(event)), sizeof chosen_network);
    // A network joined before needs no typing.
    if (wifi_link_saved(chosen_network)) { wifi_link_join(chosen_network, NULL); return; }
    lv_textarea_set_text(password_field, "");
    lv_textarea_set_placeholder_text(password_field, chosen_network);
    lv_obj_add_flag(network_list, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(password_row, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(keyboard, LV_OBJ_FLAG_HIDDEN);
}

static void keyboard_done(lv_event_t *event) {
    if (lv_event_get_code(event) == LV_EVENT_READY) join_network(event);
    else {   // cancelled
        lv_obj_add_flag(password_row, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(keyboard, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(network_list, LV_OBJ_FLAG_HIDDEN);
    }
}

static void forget_mac(lv_event_t *event) {
    (void)event;
    app_forget_mac();
}

static lv_obj_t *small_button(lv_obj_t *parent, const char *text, lv_event_cb_t action) {
    lv_obj_t *item = lv_button_create(parent);
    lv_obj_set_size(item, 150, 52);
    lv_obj_add_event_cb(item, action, LV_EVENT_CLICKED, NULL);
    lv_obj_t *label = lv_label_create(item);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_20, 0);
    lv_obj_center(label);
    return item;
}

/// Called from refresh() while the panel is open.
static void refresh_wireless(void) {
    char wifi[96], bluetooth[96];
    wifi_link_status(wifi, sizeof wifi);
    ble_link_status(bluetooth, sizeof bluetooth);
    lv_label_set_text_fmt(wireless_status, "USB: %s\nWi-Fi: %s\n%s",
        usb_link_host_present() ? "computer detected" : "no computer detected on the USB port", wifi, bluetooth);
    core_lock();
    app_mac_t mac = g_mac;
    core_unlock();
    if (mac.valid) lv_label_set_text_fmt(mac_status, "Paired with %s. It connects by itself when the Mac app is running.", mac.name);
    else lv_label_set_text(mac_status, "Not paired. Plug the USB port into your Mac and click \"Remember this board\" in the Mac app.");
    if (mac.valid) lv_obj_remove_flag(forget_button, LV_OBJ_FLAG_HIDDEN); else lv_obj_add_flag(forget_button, LV_OBJ_FLAG_HIDDEN);

    static char names[16][33];
    bool scanning;
    int count = wifi_link_networks(names, 16, &scanning);
    static bool first_scan_done;
    if (listed_networks == -1) first_scan_done = false;
    if (!first_scan_done && !scanning && count == 0) { wifi_link_scan(); first_scan_done = true; }
    int shown = scanning ? -2 : count;
    if (shown == listed_networks) return;
    listed_networks = shown;
    lv_obj_clean(network_list);
    if (scanning) lv_list_add_text(network_list, "Looking for networks...");
    else if (count == 0) lv_list_add_text(network_list, "No networks found. Tap Scan.");
    else lv_list_add_text(network_list, "Networks with a tick are remembered: tap to join without a password.");
    for (int i = 0; !scanning && i < count; i++) {
        lv_obj_t *item = lv_list_add_button(network_list, wifi_link_saved(names[i]) ? LV_SYMBOL_OK : LV_SYMBOL_WIFI, names[i]);
        lv_obj_set_style_text_font(item, &lv_font_montserrat_20, 0);
        lv_obj_set_style_min_height(item, 56, 0);
        lv_obj_add_event_cb(item, network_chosen, LV_EVENT_CLICKED, NULL);
    }
}

static void open_wireless(lv_event_t *event) {
    (void)event;
    if (wireless_panel) return;
    wireless_panel = lv_obj_create(lv_screen_active());
    lv_obj_set_size(wireless_panel, BOARD_H_RES, BOARD_V_RES);
    lv_obj_set_pos(wireless_panel, 0, 0);
    lv_obj_set_style_radius(wireless_panel, 0, 0);
    lv_obj_set_style_border_width(wireless_panel, 0, 0);
    lv_obj_set_style_bg_color(wireless_panel, lv_color_hex(0x0b0d10), 0);
    lv_obj_set_style_text_color(wireless_panel, lv_color_hex(0xffffff), 0);
    lv_obj_set_style_pad_hor(wireless_panel, 40, 0);
    lv_obj_set_style_pad_ver(wireless_panel, 16, 0);
    lv_obj_set_style_pad_row(wireless_panel, 10, 0);
    lv_obj_set_flex_flow(wireless_panel, LV_FLEX_FLOW_COLUMN);
    lv_obj_remove_flag(wireless_panel, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *top = settings_row(wireless_panel, "Wireless");
    lv_obj_set_flex_grow(top, 0);
    lv_obj_set_height(top, 60);
    lv_obj_set_style_text_font(lv_obj_get_child(top, 0), &lv_font_montserrat_28, 0);
    lv_obj_t *buttons = lv_obj_create(top);
    lv_obj_remove_style_all(buttons);
    lv_obj_set_size(buttons, 320, 52);
    lv_obj_set_flex_flow(buttons, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(buttons, 16, 0);
    small_button(buttons, "Scan", rescan);
    small_button(buttons, "Done", close_wireless);

    mac_status = lv_label_create(wireless_panel);
    lv_obj_set_width(mac_status, lv_pct(100));
    lv_label_set_long_mode(mac_status, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(mac_status, &lv_font_montserrat_20, 0);
    lv_obj_t *choices = lv_obj_create(wireless_panel);
    lv_obj_remove_style_all(choices);
    lv_obj_set_size(choices, lv_pct(100), 52);
    lv_obj_set_flex_flow(choices, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(choices, 16, 0);
    forget_button = small_button(choices, "Forget Mac", forget_mac);

    wireless_status = lv_label_create(wireless_panel);
    lv_obj_set_style_text_font(wireless_status, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(wireless_status, lv_color_hex(0x6cb2ff), 0);

    network_list = lv_list_create(wireless_panel);
    lv_obj_set_width(network_list, lv_pct(100));
    lv_obj_set_flex_grow(network_list, 1);
    lv_obj_set_style_bg_color(network_list, lv_color_hex(0x1c1f24), 0);
    lv_obj_set_style_text_color(network_list, lv_color_hex(0xffffff), 0);
    lv_obj_set_style_border_width(network_list, 0, 0);

    password_row = lv_obj_create(wireless_panel);
    lv_obj_remove_style_all(password_row);
    lv_obj_set_size(password_row, lv_pct(100), 56);
    lv_obj_set_flex_flow(password_row, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(password_row, 16, 0);
    password_field = lv_textarea_create(password_row);
    lv_textarea_set_one_line(password_field, true);
    lv_obj_set_flex_grow(password_field, 1);
    lv_obj_set_style_text_font(password_field, &lv_font_montserrat_24, 0);
    small_button(password_row, "Join", join_network);
    lv_obj_add_flag(password_row, LV_OBJ_FLAG_HIDDEN);

    keyboard = lv_keyboard_create(wireless_panel);
    lv_obj_set_size(keyboard, lv_pct(100), 300);
    lv_obj_set_style_text_font(keyboard, &lv_font_montserrat_20, 0);
    lv_keyboard_set_textarea(keyboard, password_field);
    lv_obj_add_event_cb(keyboard, keyboard_done, LV_EVENT_READY, NULL);
    lv_obj_add_event_cb(keyboard, keyboard_done, LV_EVENT_CANCEL, NULL);
    lv_obj_add_flag(keyboard, LV_OBJ_FLAG_HIDDEN);

    listed_networks = -1;
    g_wifi_setup = true;   // the power task switches Wi-Fi on for this page
    refresh_wireless();
}

/// Settings is replaced by the wireless page rather than stacked under it.
static void settings_to_wireless(lv_event_t *event) {
    lv_obj_delete_async(settings_panel);
    settings_panel = NULL;
    core_lock();
    bool changed = memcmp(&settings_at_open, &g_settings, sizeof g_settings) != 0;
    core_unlock();
    if (changed) app_save_settings();
    open_wireless(event);
}

static void close_settings(lv_event_t *event) {
    (void)event;
    // Deleting the panel from inside its own button's event would tear the
    // object tree down mid-event; let LVGL do it after the event returns.
    lv_obj_delete_async(settings_panel);
    settings_panel = NULL;
    g_ui_modal = false;
    g_ui_dirty = true;
    // Writing flash briefly stalls the display, so only do it for a real change.
    core_lock();
    bool changed = memcmp(&settings_at_open, &g_settings, sizeof g_settings) != 0;
    core_unlock();
    if (changed) app_save_settings();
}

static void heading(lv_obj_t *parent, const char *text) {
    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(label, lv_color_hex(0x6cb2ff), 0);
    lv_obj_set_style_pad_top(label, 16, 0);
}

static lv_obj_t *settings_column(lv_obj_t *parent) {
    lv_obj_t *column = lv_obj_create(parent);
    lv_obj_remove_style_all(column);
    lv_obj_set_height(column, lv_pct(100));
    lv_obj_set_flex_grow(column, 1);
    lv_obj_set_flex_flow(column, LV_FLEX_FLOW_COLUMN);
    lv_obj_remove_flag(column, LV_OBJ_FLAG_SCROLLABLE);
    return column;
}

/// Everything fits on one screen in two columns, so nothing has to scroll:
/// redrawing the whole 1024x600 panel while it scrolls is visibly jerky.
static void open_settings(lv_event_t *event) {
    (void)event;
    if (settings_panel) return;
    // Nothing may stay held on the Mac while the pad is covered.
    core_lock();
    tp_engine_cancel(&g_engine, forward, NULL);
    g_dragging = false;
    tp_command_t release = { .kind = TP_RELEASE_ALL };
    forward(&release, NULL);
    app_settings_t now = g_settings;
    core_unlock();
    settings_at_open = now;
    g_ui_modal = true;

    settings_panel = lv_obj_create(lv_screen_active());
    lv_obj_set_size(settings_panel, BOARD_H_RES, BOARD_V_RES);
    lv_obj_set_pos(settings_panel, 0, 0);
    lv_obj_set_style_radius(settings_panel, 0, 0);
    lv_obj_set_style_border_width(settings_panel, 0, 0);
    lv_obj_set_style_bg_color(settings_panel, lv_color_hex(0x0b0d10), 0);
    // The default theme's dark text is unreadable on this background.
    lv_obj_set_style_text_color(settings_panel, lv_color_hex(0xffffff), 0);
    lv_obj_set_style_pad_hor(settings_panel, 40, 0);
    lv_obj_set_style_pad_ver(settings_panel, 16, 0);
    lv_obj_set_flex_flow(settings_panel, LV_FLEX_FLOW_COLUMN);
    lv_obj_remove_flag(settings_panel, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *top = settings_row(settings_panel, "Settings");
    lv_obj_set_flex_grow(top, 0);
    lv_obj_set_height(top, 60);
    lv_obj_set_style_text_font(lv_obj_get_child(top, 0), &lv_font_montserrat_28, 0);
    lv_obj_t *buttons = lv_obj_create(top);
    lv_obj_remove_style_all(buttons);
    lv_obj_set_size(buttons, 320, 52);
    lv_obj_set_flex_flow(buttons, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(buttons, 16, 0);
    small_button(buttons, "Wireless", settings_to_wireless);
    small_button(buttons, "Done", close_settings);

    lv_obj_t *columns = lv_obj_create(settings_panel);
    lv_obj_remove_style_all(columns);
    lv_obj_set_width(columns, lv_pct(100));
    lv_obj_set_flex_grow(columns, 1);
    lv_obj_set_flex_flow(columns, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(columns, 64, 0);
    lv_obj_remove_flag(columns, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_t *left = settings_column(columns), *right = settings_column(columns);

    heading(left, "MOVEMENT AND SCROLLING");
    add_speed(left, "Pointer speed", 0, now.sensitivity);
    add_speed(left, "Scroll speed", 1, now.scroll_speed);
    add_switch(left, "Natural scrolling", SET_NATURAL);
    heading(left, "TWO AND FOUR FINGERS");
    add_switch(left, "Pinch to zoom", SET_PINCH);
    add_switch(left, "Mission Control (4 fingers)", SET_MISSION);
    // The heading says which of the two levels this is; a longer row label
    // would not fit beside the slider.
    heading(left, usb_link_host_present() ? "SCREEN, ON A COMPUTER'S USB PORT" : "SCREEN, ON BATTERY");
    add_speed(left, "Brightness", 2, app_brightness());

    heading(right, "CLICK AND DRAG");
    add_switch(right, "Tap to click", SET_TAP);
    add_switch(right, "Two-finger right-click", SET_TWO_FINGER);
    add_switch(right, "Hold to drag", SET_HOLD);
    heading(right, "THREE FINGERS: ONE OR THE OTHER");
    add_switch(right, "Three-finger drag", SET_THREE_DRAG);
    add_switch(right, "Page swipes", SET_PAGES);
    show_switches();
}

static void toggle_connection(lv_event_t *event) {
    (void)event;
    app_set_paused(!g_paused);
}

static void sleep_pressed(lv_event_t *event) {
    (void)event;
    // Nothing may stay held on the Mac while the board sleeps.
    core_lock();
    tp_engine_cancel(&g_engine, forward, NULL);
    g_dragging = false;
    app_sleep();
    core_unlock();
}

static void close_route_menu(lv_event_t *event) {
    (void)event;
    if (!route_menu) return;
    lv_obj_delete_async(route_menu);
    route_menu = NULL;
    g_ui_modal = false;
}

static void route_chosen(lv_event_t *event) {
    app_set_route((app_route_t)(uintptr_t)lv_event_get_user_data(event));
    close_route_menu(event);
}

/// The route button: a menu of the three routes under it.
static void open_route_menu(lv_event_t *event) {
    (void)event;
    if (route_menu) return;
    // A see-through sheet over everything: a touch outside the menu closes it.
    g_ui_modal = true;
    route_menu = lv_obj_create(lv_layer_top());
    lv_obj_remove_style_all(route_menu);
    lv_obj_set_size(route_menu, BOARD_H_RES, BOARD_V_RES);
    lv_obj_add_flag(route_menu, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(route_menu, close_route_menu, LV_EVENT_CLICKED, NULL);
    lv_obj_t *list = lv_obj_create(route_menu);
    lv_obj_remove_style_all(list);
    lv_obj_set_size(list, lv_obj_get_width(route_button) + 16, 3 * 64 + 2 * 8 + 16);
    lv_obj_set_pos(list, lv_obj_get_x(route_button) + 12 - 8, BAR_HEIGHT - 4);
    lv_obj_set_style_bg_color(list, lv_color_hex(0x0b0d10), 0);
    lv_obj_set_style_bg_opa(list, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(list, 18, 0);
    lv_obj_set_style_border_color(list, lv_color_hex(0x2f6fbd), 0);
    lv_obj_set_style_border_width(list, 2, 0);
    lv_obj_set_style_pad_all(list, 8, 0);
    lv_obj_set_style_pad_row(list, 8, 0);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_remove_flag(list, LV_OBJ_FLAG_SCROLLABLE);
    static const char *const names[] = { LV_SYMBOL_USB "  USB", LV_SYMBOL_WIFI "  Wi-Fi", LV_SYMBOL_BLUETOOTH "  Bluetooth" };
    for (int i = 0; i < 3; i++) {
        app_route_t route = (app_route_t)i;
        lv_obj_t *item = lv_button_create(list);
        lv_obj_set_size(item, lv_pct(100), 64);
        lv_obj_set_style_radius(item, 14, 0);
        lv_obj_set_style_shadow_width(item, 0, 0);
        lv_obj_set_style_bg_color(item, lv_color_hex(route == g_route ? 0x2f6fbd : 0x1f3a5f), 0);
        lv_obj_add_event_cb(item, route_chosen, LV_EVENT_CLICKED, (void *)(uintptr_t)route);
        lv_obj_t *label = lv_label_create(item);
        lv_label_set_text(label, names[i]);
        lv_obj_set_style_text_font(label, &lv_font_montserrat_20, 0);
        lv_obj_center(label);
    }
}

static lv_obj_t *top_button(lv_obj_t *parent, const char *text, lv_event_cb_t action) {
    lv_obj_t *item = lv_button_create(parent);
    lv_obj_set_height(item, lv_pct(100));
    lv_obj_set_flex_grow(item, 1);
    lv_obj_set_style_radius(item, 14, 0);
    lv_obj_set_style_bg_color(item, lv_color_hex(0x2a2f37), 0);
    lv_obj_set_style_shadow_width(item, 0, 0);
    lv_obj_set_style_pad_hor(item, 4, 0);
    lv_obj_add_event_cb(item, action, LV_EVENT_CLICKED, NULL);
    lv_obj_t *label = lv_label_create(item);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_20, 0);
    lv_obj_center(label);
    return item;
}

static void read_pointer(lv_indev_t *device, lv_indev_data_t *data) {
    (void)device;
    ui_pointer_t pointer = g_ui_pointer;
    data->point.x = pointer.x; data->point.y = pointer.y;
    data->state = pointer.pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

void ui_start(void) {
    if (!lvgl_port_lock(0)) return;
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(0x0b0d10), 0);
    lv_obj_set_style_text_color(screen, lv_color_hex(0xd8dee9), 0);
    lv_obj_remove_flag(screen, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *pad = lv_obj_create(screen);
    lv_obj_set_size(pad, PAD_WIDTH - 24, BOARD_V_RES - BAR_HEIGHT - 12);
    lv_obj_set_pos(pad, 12, BAR_HEIGHT);
    lv_obj_set_style_radius(pad, 24, 0);
    lv_obj_set_style_bg_color(pad, lv_color_hex(0x1c1f24), 0);
    lv_obj_set_style_border_width(pad, 0, 0);
    lv_obj_remove_flag(pad, LV_OBJ_FLAG_SCROLLABLE | LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_flex_flow(pad, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(pad, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(pad, 14, 0);
    lv_obj_set_style_text_color(pad, lv_color_hex(0x8a93a3), 0);
    title = lv_label_create(pad);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_28, 0);
    hint = lv_label_create(pad);
    lv_obj_set_style_text_font(hint, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_align(hint, LV_TEXT_ALIGN_CENTER, 0);
    status = lv_label_create(pad);
    lv_obj_set_style_text_font(status, &lv_font_montserrat_14, 0);

    strip_title = lv_label_create(screen);
    lv_obj_set_style_text_font(strip_title, &lv_font_montserrat_20, 0);
    lv_obj_set_width(strip_title, STRIP_WIDTH - 12);
    lv_obj_set_style_text_align(strip_title, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_pos(strip_title, PAD_WIDTH, BAR_HEIGHT + 4);

    // Connection controls across the whole width, so the strip stays app-specific.
    lv_obj_t *bar = lv_obj_create(screen);
    lv_obj_remove_style_all(bar);
    lv_obj_set_size(bar, BOARD_H_RES - 24, BAR_HEIGHT - 16);
    lv_obj_set_pos(bar, 12, 8);
    lv_obj_set_flex_flow(bar, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(bar, 8, 0);
    lv_obj_remove_flag(bar, LV_OBJ_FLAG_SCROLLABLE);
    connect_button = top_button(bar, "", toggle_connection);
    route_button = top_button(bar, "", open_route_menu);
    lv_obj_set_style_bg_color(route_button, lv_color_hex(0x1f3a5f), 0);   // it opens a menu
    top_button(bar, LV_SYMBOL_SETTINGS "  Settings", open_settings);
    lv_obj_t *battery = lv_obj_create(bar);
    lv_obj_remove_style_all(battery);
    lv_obj_set_size(battery, 150, lv_pct(100));
    lv_obj_set_style_radius(battery, 14, 0);
    lv_obj_set_style_bg_color(battery, lv_color_hex(0x1c1f24), 0);
    lv_obj_set_style_bg_opa(battery, LV_OPA_COVER, 0);
    lv_obj_remove_flag(battery, LV_OBJ_FLAG_SCROLLABLE);
    battery_label = lv_label_create(battery);
    lv_obj_set_style_text_font(battery_label, &lv_font_montserrat_16, 0);
    lv_label_set_text(battery_label, "");
    lv_obj_center(battery_label);
    // Square, in the corner: screen off and offline until the next touch.
    lv_obj_t *power = top_button(bar, LV_SYMBOL_POWER, sleep_pressed);
    lv_obj_set_flex_grow(power, 0);
    lv_obj_set_width(power, BAR_HEIGHT - 16);

    strip = lv_obj_create(screen);
    lv_obj_remove_style_all(strip);
    lv_obj_set_size(strip, STRIP_WIDTH - 12, BOARD_V_RES - BAR_HEIGHT - 36 - 8);
    lv_obj_set_pos(strip, PAD_WIDTH, BAR_HEIGHT + 36);
    lv_obj_set_flex_flow(strip, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(strip, 12, 0);
    lv_obj_set_style_pad_bottom(strip, 8, 0);
    lv_obj_set_scroll_dir(strip, LV_DIR_VER);
    lv_obj_add_flag(strip, LV_OBJ_FLAG_SCROLLABLE);

    lv_indev_t *pointer = lv_indev_create();
    lv_indev_set_type(pointer, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(pointer, read_pointer);

    lv_timer_create(refresh, 50, NULL);
    lvgl_port_unlock();
}
