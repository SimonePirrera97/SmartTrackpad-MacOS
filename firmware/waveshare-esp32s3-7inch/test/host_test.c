// Desktop check of the portable core against the shared protocol fixtures.
// Run from the repository root through scripts/check.sh.
#include "trackpad_core.h"
#include "cJSON.h"
#include "../main/ui_pointer_queue.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition, ...) do { if (!(condition)) { fprintf(stderr, "FAILED %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); exit(1); } } while (0)

static char *read_file(const char *path) {
    FILE *file = fopen(path, "rb");
    CHECK(file, "cannot open %s", path);
    fseek(file, 0, SEEK_END); long size = ftell(file); rewind(file);
    char *text = malloc((size_t)size + 1);
    CHECK(fread(text, 1, (size_t)size, file) == (size_t)size, "short read");
    text[size] = 0; fclose(file);
    return text;
}

typedef struct { tp_command_t items[64]; int count; } list_t;
static void collect(const tp_command_t *command, void *context) {
    list_t *list = context;
    CHECK(list->count < 64, "too many commands");
    CHECK(tp_command_valid(command), "engine produced an invalid command of kind %d", command->kind);
    list->items[list->count++] = *command;
}

static const char *kinds[] = { "move", "click", "button", "scroll", "releaseAll", "stopMomentum", "action",
    "magnify", "pageSwipe", "missionControl", "showDesktop", "appControl" };
static const char *phases[] = { "began", "changed", "ended", "cancelled" };

static int index_of(const char *const *names, int count, const cJSON *value) {
    if (!cJSON_IsString(value)) return -1;
    for (int i = 0; i < count; i++) if (strcmp(names[i], value->valuestring) == 0) return i;
    return -1;
}
static double number(const cJSON *object, const char *key) {
    const cJSON *value = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsNumber(value) ? value->valuedouble : 0;
}

static void check_trace(const char *name) {
    char path[256];
    snprintf(path, sizeof path, "protocol/fixtures/gestures/%s.json", name);
    char *text = read_file(path);
    cJSON *trace = cJSON_Parse(text);
    CHECK(trace, "bad JSON in %s", path);
    tp_engine_t engine; tp_engine_init(&engine);
    engine.options.mission_control = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(trace, "interactiveMissionControl"));
    engine.options.page_swipes = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(trace, "pageSwipes"));
    const cJSON *sample; int row = 0;
    cJSON_ArrayForEach(sample, cJSON_GetObjectItemCaseSensitive(trace, "samples")) {
        tp_touches_t touches = { 0 };
        const cJSON *touch;
        cJSON_ArrayForEach(touch, cJSON_GetObjectItemCaseSensitive(sample, "touches")) {
            touches.items[touches.count++] = (tp_touch_t){ atoi(touch->string), number(touch, "x"), number(touch, "y") };
        }
        list_t out = { .count = 0 };
        tp_engine_update(&engine, &touches, number(sample, "time"), collect, &out);
        const cJSON *expected = cJSON_GetObjectItemCaseSensitive(sample, "expected");
        CHECK(cJSON_GetArraySize(expected) == out.count, "%s sample %d: %d commands, expected %d", name, row, out.count, cJSON_GetArraySize(expected));
        for (int i = 0; i < out.count; i++) {
            const cJSON *want = cJSON_GetArrayItem(expected, i);
            const tp_command_t *got = &out.items[i];
            CHECK(index_of(kinds, 12, cJSON_GetObjectItemCaseSensitive(want, "kind")) == (int)got->kind, "%s sample %d command %d: kind", name, row, i);
            const cJSON *delta = cJSON_GetObjectItemCaseSensitive(want, "delta");
            if (delta) CHECK(fabs(number(delta, "dx") - got->dx) < 1e-9 && fabs(number(delta, "dy") - got->dy) < 1e-9, "%s sample %d command %d: delta", name, row, i);
            const cJSON *phase = cJSON_GetObjectItemCaseSensitive(want, "phase");
            if (phase) CHECK(index_of(phases, 4, phase) == (int)got->phase, "%s sample %d command %d: phase", name, row, i);
            const cJSON *button = cJSON_GetObjectItemCaseSensitive(want, "button");
            if (button) CHECK((strcmp(button->valuestring, "right") == 0) == (got->button == TP_RIGHT), "%s sample %d command %d: button", name, row, i);
            const cJSON *pressed = cJSON_GetObjectItemCaseSensitive(want, "pressed");
            if (pressed) CHECK(cJSON_IsTrue(pressed) == got->pressed, "%s sample %d command %d: pressed", name, row, i);
            const cJSON *count = cJSON_GetObjectItemCaseSensitive(want, "count");
            if (count) CHECK(count->valueint == got->count, "%s sample %d command %d: count", name, row, i);
            const cJSON *progress = cJSON_GetObjectItemCaseSensitive(want, "progress");
            if (progress) CHECK(fabs(progress->valuedouble - got->value) < 1e-9, "%s sample %d command %d: progress", name, row, i);
            const cJSON *magnification = cJSON_GetObjectItemCaseSensitive(want, "magnification");
            if (magnification) CHECK(fabs(magnification->valuedouble - got->value) < 1e-9, "%s sample %d command %d: magnification", name, row, i);
        }
        row++;
    }
    cJSON_Delete(trace); free(text);
}

static void hex(const uint8_t *bytes, size_t length, char *out) {
    for (size_t i = 0; i < length; i++) snprintf(out + i * 2, 3, "%02x", bytes[i]);
}

// A scripted Mac on the other end of the session.
typedef struct { char sent[8192]; size_t length; int changes; char reason[96]; } link_t;
static bool link_write(const uint8_t *bytes, size_t length, void *context) {
    link_t *link = context;
    CHECK(link->length + length < sizeof link->sent, "link overflow");
    memcpy(link->sent + link->length, bytes, length); link->length += length;
    return true;
}
static void link_changed(void *context, const char *reason) {
    link_t *link = context; link->changes++;
    snprintf(link->reason, sizeof link->reason, "%s", reason ? reason : "");
}

static void pinch_and_balance(void) {
    // Two fingers spreading apart must begin, change and end a pinch, never scroll.
    tp_engine_t engine; tp_engine_init(&engine); engine.options.pinch = true;
    list_t out = { .count = 0 };
    for (int step = 0; step <= 10; step++) {
        tp_touches_t touches = { 2, { { 1, 400 - step * 10, 300 }, { 2, 600 + step * 10, 300 } } };
        tp_engine_update(&engine, &touches, step * 0.02, collect, &out);
    }
    tp_touches_t none = { 0 };
    tp_engine_update(&engine, &none, 0.3, collect, &out);
    int began = 0, ended = 0; double product = 1;
    for (int i = 0; i < out.count; i++) {
        CHECK(out.items[i].kind == TP_MAGNIFY || out.items[i].kind == TP_STOP_MOMENTUM, "pinch leaked kind %d", out.items[i].kind);
        if (out.items[i].kind != TP_MAGNIFY) continue;
        if (out.items[i].phase == TP_BEGAN) began++;
        if (out.items[i].phase == TP_ENDED) ended++;
        product *= 1 + out.items[i].value;
    }
    CHECK(began == 1 && ended == 1 && fabs(product - 2.0) < 1e-6, "pinch began %d ended %d product %f", began, ended, product);

    // Tap, then slide on the second contact: press before motion, release on
    // lift, never add a click. Plain double taps and disabled drag still work.
    for (int variant = 0; variant < 5; variant++) {
        tp_engine_t tapdrag; tp_engine_init(&tapdrag);
        tapdrag.options.hold_to_drag = false;
        tapdrag.options.tap_to_drag = variant != 2;
        list_t events = { 0 };
        tp_touches_t finger = { .count = 1, .items = { { 1, 100, 100 } } }, none = { 0 };
        tp_engine_update(&tapdrag, &finger, 0, collect, &events);
        tp_engine_update(&tapdrag, &none, 0.08, collect, &events);
        finger.items[0].id = 2;
        tp_engine_update(&tapdrag, &finger, variant == 3 ? 0.6 : 0.18, collect, &events);
        if (variant != 1) finger.items[0].x = 130;
        int before = events.count;
        tp_engine_update(&tapdrag, &finger, 0.7, collect, &events);
        if (variant == 0 || variant == 4) {
            CHECK(events.items[before].kind == TP_BUTTON && events.items[before].pressed, "tap drag must press before moving");
            CHECK(events.items[before + 1].kind == TP_MOVE, "tap drag motion missing");
        }
        if (variant == 4) tp_engine_cancel(&tapdrag, collect, &events);
        else tp_engine_update(&tapdrag, &none, 0.72, collect, &events);
        int presses = 0, releases = 0, clicks = 0;
        for (int i = 0; i < events.count; i++) {
            tp_command_t c = events.items[i];
            presses += c.kind == TP_BUTTON && c.pressed;
            releases += c.kind == TP_BUTTON && !c.pressed;
            clicks += c.kind == TP_CLICK;
        }
        CHECK(presses == (variant == 0 || variant == 4) && presses == releases, "tap drag cleanup variant %d", variant);
        CHECK(clicks == 1, "tap drag added lift click variant %d", variant);
    }
    // Two quick stationary taps retain double-click counting.
    {
        tp_engine_t e; tp_engine_init(&e); e.options.tap_to_drag = true; e.options.hold_to_drag = false;
        list_t events = { 0 };
        tp_touches_t one = { .count = 1, .items = { { 1, 100, 100 } } }, none = { 0 };
        tp_engine_update(&e, &one, 0, collect, &events);
        tp_engine_update(&e, &none, 0.05, collect, &events);
        tp_engine_update(&e, &one, 0.1, collect, &events);
        tp_engine_update(&e, &none, 0.15, collect, &events);
        CHECK(events.items[events.count - 1].kind == TP_CLICK && events.items[events.count - 1].count == 2, "double tap changed");
    }

    // Board defaults: three fingers drag, four fingers drive Mission Control.
    tp_engine_init(&engine);
    engine.options.three_finger_drag = engine.options.mission_control = true;
    engine.options.mission_fingers = 4;
    out.count = 0;
    for (int step = 0; step <= 6; step++) {   // fingers land one after another, then swipe up
        tp_touches_t touches = { 0 };
        int fingers = step < 3 ? step + 2 : 4;
        double y = step < 3 ? 400 : 400 - (step - 2) * 40;
        for (int i = 0; i < fingers; i++) touches.items[touches.count++] = (tp_touch_t){ i + 1, 200 + i * 90, y };
        tp_engine_update(&engine, &touches, step * 0.02, collect, &out);
    }
    tp_touches_t three = { 3, { { 1, 200, 240 }, { 2, 290, 240 }, { 3, 380, 240 } } };
    tp_engine_update(&engine, &three, 0.16, collect, &out);
    three.items[0].y = three.items[1].y = three.items[2].y = 300;
    tp_engine_update(&engine, &three, 0.18, collect, &out);   // the three left over must not drag
    tp_engine_update(&engine, &none, 0.2, collect, &out);
    int mission_began = 0, mission_ended = 0; double last_progress = 0;
    for (int i = 0; i < out.count; i++) {
        CHECK(out.items[i].kind == TP_MISSION_CONTROL || out.items[i].kind == TP_STOP_MOMENTUM, "four-finger swipe leaked kind %d", out.items[i].kind);
        if (out.items[i].kind != TP_MISSION_CONTROL) continue;
        if (out.items[i].phase == TP_BEGAN) mission_began++;
        if (out.items[i].phase == TP_ENDED) mission_ended++;
        if (out.items[i].phase == TP_CHANGED) last_progress = out.items[i].value;
    }
    CHECK(mission_began == 1 && mission_ended == 1 && fabs(last_progress - 160.0 / 300) < 1e-9, "four-finger Mission Control: began %d ended %d progress %f", mission_began, mission_ended, last_progress);
    out.count = 0;
    for (int step = 0; step <= 4; step++) {   // three fingers still drag
        tp_touches_t touches = { 3, { { 1, 200 + step * 20, 300 }, { 2, 290 + step * 20, 300 }, { 3, 380 + step * 20, 300 } } };
        tp_engine_update(&engine, &touches, 1 + step * 0.02, collect, &out);
    }
    tp_engine_update(&engine, &none, 1.2, collect, &out);
    int presses = 0, releases = 0, moves = 0;
    for (int i = 0; i < out.count; i++) {
        if (out.items[i].kind == TP_BUTTON) { if (out.items[i].pressed) presses++; else releases++; }
        if (out.items[i].kind == TP_MOVE) moves++;
        CHECK(out.items[i].kind != TP_MISSION_CONTROL && out.items[i].kind != TP_PAGE_SWIPE, "three-finger drag navigated");
    }
    CHECK(presses == 1 && releases == 1 && moves >= 3, "three-finger drag: %d presses %d releases %d moves", presses, releases, moves);

    // Board option: a second finger joins a hold-drag instead of ending it.
    for (int join = 0; join < 2; join++) {
        tp_engine_init(&engine);
        engine.options.pinch = true;
        engine.options.drag_second_finger = join;
        out.count = 0;
        double t = 2;
        tp_touches_t one = { 1, { { 1, 300, 300 } } }, two = { 2, { { 1, 300, 300 }, { 2, 500, 300 } } };
        tp_engine_update(&engine, &one, t, collect, &out);
        tp_engine_update(&engine, &one, t += 0.5, collect, &out);              // held long enough: button down
        tp_engine_update(&engine, &two, t += 0.02, collect, &out);             // second finger lands
        for (int step = 1; step <= 5; step++) {                                // and slides while the first holds
            two.items[1].x = 500 + step * 20;
            tp_engine_update(&engine, &two, t += 0.02, collect, &out);
        }
        tp_touches_t second = { 1, { { 2, 600, 300 } } };                      // the holding finger lifts
        tp_engine_update(&engine, &second, t += 0.02, collect, &out);
        second.items[0].y = 330;
        tp_engine_update(&engine, &second, t += 0.02, collect, &out);
        int down = 0, up = 0, up_at = -1; double x = 0, y = 0;
        for (int i = 0; i < out.count; i++) {
            const tp_command_t *c = &out.items[i];
            if (c->kind == TP_BUTTON) { if (c->pressed) down++; else { up++; up_at = i; } }
            if (c->kind == TP_MOVE && down == 1 && up == 0) { x += c->dx; y += c->dy; }
            CHECK(c->kind != TP_SCROLL && c->kind != TP_MAGNIFY && c->kind != TP_CLICK, "second finger on a drag produced kind %d", c->kind);
        }
        if (join) CHECK(down == 1 && up == 0 && x == 100 && y == 30, "joined drag: %d down %d up, moved %f %f", down, up, x, y);
        else CHECK(down == 1 && up == 1 && x == 0 && y == 0, "plain drag: %d down %d up, moved %f %f", down, up, x, y);
        int before = out.count;
        tp_engine_update(&engine, &none, t += 0.02, collect, &out);            // last finger lifts
        for (int i = before; i < out.count; i++) if (out.items[i].kind == TP_BUTTON && !out.items[i].pressed) { up++; up_at = i; }
        CHECK(up == 1 && up_at >= 0, "drag released %d times", up);
        for (int i = before; i < out.count; i++) CHECK(out.items[i].kind != TP_CLICK, "lifting after a drag clicked");
        // A third finger ends the joined drag.
        if (join) {
            out.count = 0;
            tp_engine_update(&engine, &one, t += 1, collect, &out);
            tp_engine_update(&engine, &one, t += 0.5, collect, &out);
            tp_engine_update(&engine, &two, t += 0.02, collect, &out);
            tp_touches_t triple = { 3, { { 1, 300, 300 }, { 2, 500, 300 }, { 3, 600, 300 } } };
            tp_engine_update(&engine, &triple, t += 0.02, collect, &out);
            tp_engine_update(&engine, &none, t += 0.02, collect, &out);
            int balance = 0;
            for (int i = 0; i < out.count; i++) if (out.items[i].kind == TP_BUTTON) balance += out.items[i].pressed ? 1 : -1;
            CHECK(balance == 0, "third finger left the button held");
        }
    }

    // Hostile contact churn: every press must be released, every gesture closed.
    for (int variant = 0; variant < 2; variant++) {
    tp_engine_init(&engine);
    engine.options.pinch = engine.options.mission_control = engine.options.page_swipes = true;
    if (variant == 1) { engine.options.three_finger_drag = true; engine.options.mission_fingers = 4; engine.options.drag_second_finger = true; }
    uint64_t seed = 42; int held = 0, scrolling = 0, pinching = 0, navigating = 0;
    for (int frame = 0; frame <= 20000; frame++) {
        seed = seed * 6364136223846793005ULL + 1;
        tp_touches_t touches = { 0 };
        int count = frame == 20000 ? 0 : (int)((seed >> 32) % 5);
        for (int i = 0; i < count; i++) {
            seed = seed * 6364136223846793005ULL + 1;
            touches.items[touches.count++] = (tp_touch_t){ (int)((seed >> 40) % 6) * 10 + i, (double)((seed >> 20) % 1000), (double)((seed >> 8) % 600) };
        }
        out.count = 0;
        tp_engine_update(&engine, &touches, frame * 0.01, collect, &out);
        for (int i = 0; i < out.count; i++) {
            const tp_command_t *c = &out.items[i];
            bool open = c->phase == TP_BEGAN || c->phase == TP_CHANGED;
            if (c->kind == TP_BUTTON) held += c->pressed ? 1 : -1;
            if (c->kind == TP_SCROLL) scrolling = open;
            if (c->kind == TP_MAGNIFY) pinching = open;
            if (c->kind == TP_PAGE_SWIPE || c->kind == TP_MISSION_CONTROL) navigating = open;
            CHECK(held == 0 || held == 1, "unbalanced button at frame %d", frame);
        }
    }
    CHECK(!held && !scrolling && !pinching && !navigating, "left held %d scrolling %d pinching %d navigating %d", held, scrolling, pinching, navigating);
    }
}

int main(void) {
    ui_pointer_queue_t pointers = { 0 };
    // A complete quick tap can arrive between two LVGL reads.
    ui_pointer_push(&pointers, (ui_pointer_t){ true, 800, 120 });
    ui_pointer_push(&pointers, (ui_pointer_t){ false, 800, 120 });
    CHECK(ui_pointer_pop(&pointers).pressed, "quick UI tap lost its press");
    CHECK(!ui_pointer_pop(&pointers).pressed, "quick UI tap lost its release");
    CHECK(!ui_pointer_pop(&pointers).pressed, "UI must retain released state");
    // Sustained motion cannot fill the mailbox or erase either edge.
    for (int i = 0; i < 1000; i++)
        ui_pointer_push(&pointers, (ui_pointer_t){ true, 800, (int16_t)i });
    CHECK(pointers.count == 1, "UI motion did not coalesce");
    ui_pointer_push(&pointers, (ui_pointer_t){ false, 800, 999 });
    ui_pointer_t point = ui_pointer_pop(&pointers);
    CHECK(point.pressed && point.y == 999, "UI motion lost its latest position");
    CHECK(!ui_pointer_pop(&pointers).pressed, "motion lost UI lift");
    for (int i = 0; i < UI_POINTER_CAPACITY; i++)
        CHECK(ui_pointer_push(&pointers, (ui_pointer_t){ i % 2 == 0, 900, 200 }), "UI queue filled early");
    CHECK(!ui_pointer_push(&pointers, (ui_pointer_t){ true, 900, 220 }), "overflow must be reported");
    CHECK(!ui_pointer_pop(&pointers).pressed, "overflow must release the old UI target");
    CHECK(ui_pointer_pop(&pointers).pressed, "overflow must preserve the current contact");
    const char *traces[] = { "tap", "drag", "scroll", "interactive-mission-control", "page-swipe" };
    for (int i = 0; i < 5; i++) check_trace(traces[i]);
    pinch_and_balance();

    // Compact encoding against the shared golden frame.
    uint8_t frame[TP_COMPACT_MAX]; char text[2 * TP_COMPACT_MAX + 1];
    tp_command_t move = { .kind = TP_MOVE, .dx = 1.25, .dy = -2.5 };
    size_t size = tp_encode_compact(&move, 2, 100000, frame);
    hex(frame, size, text);
    CHECK(strcmp(text, "d301001d000000000000000200000000000186a0003fa00000c0200000") == 0, "compact move: %s", text);
    tp_command_t scroll = { .kind = TP_SCROLL, .dx = 3, .dy = -40, .phase = TP_CHANGED, .has_sample_age = true, .sample_age_ms = 4, .has_interval = true, .interval_ms = 8 };
    CHECK(tp_encode_compact(&scroll, 3, 100000, frame) == 39, "timed scroll is not 39 bytes");
    tp_command_t bad = { .kind = TP_MOVE, .dx = 500 };
    CHECK(tp_encode_compact(&bad, 3, 1, frame) == 0, "out-of-range move was encoded");
    tp_command_t wrong_app = { .kind = TP_APP_CONTROL, .app = TP_APP_FINDER, .app_action = TP_PLAY_PAUSE };
    CHECK(!tp_command_valid(&wrong_app), "Finder accepted a Spotify action");

    // Scroll speed scaling splits oversized flicks without losing distance.
    list_t parts = { .count = 0 };
    tp_command_t flick = { .kind = TP_SCROLL, .dy = 1500, .phase = TP_BEGAN };
    tp_scale(&flick, 3, collect, &parts);
    double total = 0; for (int i = 0; i < parts.count; i++) total += parts.items[i].dy;
    CHECK(parts.count == 3 && fabs(total - 4500) < 1e-9 && parts.items[0].phase == TP_BEGAN && parts.items[1].phase == TP_CHANGED, "scroll split");

    // Cable session: request, accept with app context, input, heartbeat, context change, timeout.
    link_t link = { .length = 0 };
    static tp_session_t session;
    tp_session_init(&session, (tp_session_callbacks_t){ link_write, link_changed, &link, NULL });
    const char *uuid = "00000000-0000-4000-8000-000000000001";
    tp_session_start(&session, uuid, NULL, NULL, 1000);
    link.sent[link.length] = 0;
    CHECK(strstr(link.sent, "\"type\":\"sessionRequest\"") && strstr(link.sent, "\"input.binary.v1\"") && !strstr(link.sent, "\"code\"")
        && !strstr(link.sent, "input.ack.v1") && link.sent[link.length - 1] == '\n', "session request: %s", link.sent);
    cJSON *request = cJSON_Parse(link.sent);
    CHECK(request && cJSON_GetArraySize(cJSON_GetObjectItemCaseSensitive(request, "capabilities")) <= 16, "request is not valid JSON");
    cJSON_Delete(request);
    tp_session_send(&session, &move, 1001);
    size_t before = link.length;
    CHECK(session.state == TP_SESSION_REQUESTED, "input must wait for the accept");
    const char *accept = "{\"version\":2,\"session\":\"00000000-0000-4000-8000-000000000001\",\"sequence\":1,\"timestampMilliseconds\":50,\"type\":\"sessionAccept\","
        "\"capabilities\":[\"pointer.move\",\"mouse.click\",\"mouse.button\",\"scroll.pixel\",\"input.releaseAll\",\"scroll.stopMomentum\",\"action.standard\",\"scroll.pixel.highRange\",\"action.appControls.v2\",\"input.binary.v1\"],"
        "\"appContext\":{\"app\":\"safari\",\"token\":\"11111111-2222-3333-4444-555555555555\"}}\n";
    // Deliver in two fragments to exercise the framer.
    tp_session_receive(&session, (const uint8_t *)accept, 40, 1010);
    tp_session_receive(&session, (const uint8_t *)accept + 40, strlen(accept) - 40, 1010);
    CHECK(session.state == TP_SESSION_CONNECTED && session.has_app && session.app == TP_APP_SAFARI && session.app_token[0] == 0x11, "accept: %s", link.reason);
    CHECK(!(session.capabilities & TP_CAP_PINCH) && (session.capabilities & TP_CAP_APP_CONTROLS), "capability intersection");
    CHECK(link.length == before, "nothing may be sent before the accept");
    tp_session_send(&session, &move, 1020);
    CHECK(link.length == before + 29 && (uint8_t)link.sent[before] == 0xd3 && link.sent[before + 11] == 2, "compact input with sequence 2");
    tp_command_t pinch = { .kind = TP_MAGNIFY, .phase = TP_BEGAN };
    tp_session_send(&session, &pinch, 1021);
    CHECK(link.length == before + 29, "an unnegotiated command was sent");
    tp_session_tick(&session, 2100);
    link.sent[link.length] = 0;
    CHECK(strstr(link.sent + before + 29, "\"type\":\"heartbeat\"") && strstr(link.sent + before + 29, "\"sequence\":3"), "heartbeat");
    int changes = link.changes;
    const char *beat = "{\"version\":2,\"session\":\"00000000-0000-4000-8000-000000000001\",\"sequence\":2,\"timestampMilliseconds\":60,\"type\":\"heartbeat\","
        "\"appContext\":{\"app\":\"finder\",\"token\":\"11111111-2222-3333-4444-555555555556\"}}\n";
    tp_session_receive(&session, (const uint8_t *)beat, strlen(beat), 2200);
    CHECK(session.app == TP_APP_FINDER && link.changes == changes + 1, "app context change");
    tp_session_receive(&session, (const uint8_t *)beat, strlen(beat), 2300);
    CHECK(session.state == TP_SESSION_IDLE && strstr(link.reason, "Invalid"), "a replayed message must end the session");

    before = link.length;   // Earlier binary frames contain zero bytes.
    tp_session_start(&session, uuid, "012345", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", 5000);
    link.sent[link.length] = 0;
    CHECK(strstr(link.sent + before, "\"type\":\"pairRequest\"") && strstr(link.sent + before, "\"code\":\"012345\"") && strstr(link.sent + before, "\"boardProof\":\"0011"), "pair request");
    tp_session_tick(&session, 5000 + 60001);
    CHECK(session.state == TP_SESSION_IDLE && strstr(link.reason, "timed out"), "approval timeout");

    // A Mac that sleeps or closes its lid says so when it ends the session.
    tp_session_start(&session, "33333333-3333-4333-8333-333333333333", NULL, NULL, 2000);
    const char *resting = "{\"version\":2,\"session\":\"33333333-3333-4333-8333-333333333333\",\"sequence\":1,\"timestampMilliseconds\":5,\"type\":\"disconnect\",\"sleeping\":true}\n";
    tp_session_receive(&session, (const uint8_t *)resting, strlen(resting), 2010);
    CHECK(session.state == TP_SESSION_IDLE && strcmp(link.reason, tp_mac_resting) == 0, "resting disconnect: %s", link.reason);

    printf("PASS: board core — quick UI taps, UI motion coalescing and overflow release, golden tap/drag/scroll/Mission Control/page-swipe traces, pinch, four-finger Mission Control beside three-finger drag, second finger joining a hold-drag, 40,000 contact-churn frames with balanced cleanup, compact encoding, scroll splitting, cable and pairing handshakes, heartbeat, app context, replay rejection and timeout\n");
    return 0;
}
