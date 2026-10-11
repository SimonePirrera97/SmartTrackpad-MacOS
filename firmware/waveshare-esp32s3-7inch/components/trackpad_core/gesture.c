// C port of packages/GestureCore (TrackpadGestureEngine, PointerMotion,
// PinchMotion, NavigationGesture, MotionScaling). Keep the two in step: the
// golden traces in protocol/fixtures/gestures are checked against both.
#include "trackpad_core.h"
#include <math.h>
#include <string.h>

enum { NAV_NONE, NAV_PAGES, NAV_MISSION_CONTROL };

static double clampd(double value, double low, double high) { return value < low ? low : (value > high ? high : value); }

static const tp_touch_t *find(const tp_touches_t *touches, int id) {
    for (int i = 0; i < touches->count; i++) if (touches->items[i].id == id) return &touches->items[i];
    return NULL;
}

static bool same_ids(const tp_touches_t *a, const tp_touches_t *b) {
    if (a->count != b->count) return false;
    for (int i = 0; i < a->count; i++) if (!find(b, a->items[i].id)) return false;
    return true;
}

static void centroid(const tp_touches_t *touches, double *x, double *y) {
    double sx = 0, sy = 0;
    for (int i = 0; i < touches->count; i++) { sx += touches->items[i].x; sy += touches->items[i].y; }
    *x = sx / touches->count; *y = sy / touches->count;
}

/// The two contacts ordered by identifier.
static void ordered_pair(const tp_touches_t *touches, const tp_touch_t **first, const tp_touch_t **second) {
    bool swap = touches->items[0].id > touches->items[1].id;
    *first = &touches->items[swap ? 1 : 0]; *second = &touches->items[swap ? 0 : 1];
}

static tp_command_t command(tp_kind_t kind) { tp_command_t c; memset(&c, 0, sizeof c); c.kind = kind; return c; }
static void emit_button(tp_emit_t emit, void *context, bool pressed) {
    tp_command_t c = command(TP_BUTTON); c.button = TP_LEFT; c.pressed = pressed; emit(&c, context);
}
static void emit_scroll(tp_emit_t emit, void *context, double dx, double dy, tp_phase_t phase) {
    tp_command_t c = command(TP_SCROLL); c.dx = dx; c.dy = dy; c.phase = phase; emit(&c, context);
}
static void emit_magnify(tp_emit_t emit, void *context, double amount, tp_phase_t phase) {
    tp_command_t c = command(TP_MAGNIFY); c.value = amount; c.phase = phase; emit(&c, context);
}
static void emit_navigation(tp_emit_t emit, void *context, int axis, double progress, tp_phase_t phase) {
    tp_command_t c = command(axis == NAV_PAGES ? TP_PAGE_SWIPE : TP_MISSION_CONTROL);
    c.value = progress; c.phase = phase; emit(&c, context);
}
static void emit_click(tp_emit_t emit, void *context, tp_button_t button, int count) {
    tp_command_t c = command(TP_CLICK); c.button = button; c.count = (uint8_t)count; emit(&c, context);
}

tp_options_t tp_default_options(void) {
    return (tp_options_t){ .tap_to_click = true, .two_finger_tap = true, .hold_to_drag = true,
        .three_finger_drag = false, .pinch = false, .mission_control = false, .page_swipes = false,
        .mission_fingers = 3,
        .hold_duration = 0.45, .tap_duration = 0.28, .movement_threshold = 12.0 };
}

void tp_engine_init(tp_engine_t *engine) {
    memset(engine, 0, sizeof *engine);
    engine->options = tp_default_options();
    engine->drag_contacts = 1;
    engine->previous_scale = 1;
}

// ---- PointerMotion ----

static bool pointer_update(tp_engine_t *e, const tp_touches_t *touches, double *dx, double *dy) {
    if (touches->count != 1) { e->pointer_has = false; return false; }
    const tp_touch_t *touch = &touches->items[0];
    bool had = e->pointer_has && e->pointer_id == touch->id;
    double x = touch->x - e->pointer_x, y = touch->y - e->pointer_y;
    e->pointer_has = true; e->pointer_id = touch->id; e->pointer_x = touch->x; e->pointer_y = touch->y;
    if (!had || fabs(x) > 128 || fabs(y) > 128 || (x == 0 && y == 0)) return false;
    *dx = x; *dy = y;
    return true;
}

// ---- PinchMotion ----

static void pinch_reset(tp_engine_t *e) {
    e->pinch_count = 0; e->pinch_distance = 0; e->pinch_angle = 0; e->pinch_cancelled = false;
}

/// Stable two-contact scale relative to where the pair first touched.
static bool pinch_update(tp_engine_t *e, const tp_touches_t *touches, double *scale) {
    if (touches->count != 2) { pinch_reset(e); return false; }
    const tp_touch_t *a, *b; ordered_pair(touches, &a, &b);
    double dx = b->x - a->x, dy = b->y - a->y;
    double distance = hypot(dx, dy), angle = atan2(dy, dx);
    if (e->pinch_count != 2 || e->pinch_ids[0] != a->id || e->pinch_ids[1] != b->id) {
        e->pinch_count = 2; e->pinch_ids[0] = a->id; e->pinch_ids[1] = b->id;
        e->pinch_distance = distance; e->pinch_angle = angle; e->pinch_cancelled = distance < 60;
        return false;
    }
    double rotation = atan2(sin(angle - e->pinch_angle), cos(angle - e->pinch_angle));
    if (fabs(rotation) > 0.2 || distance < 20) e->pinch_cancelled = true;
    if (e->pinch_cancelled || e->pinch_distance <= 0) return false;
    *scale = distance / e->pinch_distance;
    return true;
}

/// Splits a scale change into bounded multiplicative steps. False if unusable.
static bool pinch_changes(double previous, double scale, int *steps, double *amount) {
    if (!isfinite(previous) || !isfinite(scale) || previous <= 0 || scale <= 0) return false;
    double ratio = scale / previous;
    if (!isfinite(ratio) || ratio <= 0) return false;
    if (fabs(ratio - 1) < 0.000001) { *steps = 0; *amount = 0; return true; }
    double count = ceil(fabs(log(ratio)) / log(1.5));
    if (!isfinite(count) || count > 16) return false;
    *steps = count < 1 ? 1 : (int)count;
    *amount = clampd(pow(ratio, 1.0 / *steps) - 1, -0.5, 0.5);
    return true;
}

// ---- NavigationGesture ----

static void navigation_reset(tp_engine_t *e) {
    e->nav_ids_count = 0; e->nav_origin_has = false; e->nav_axis = NAV_NONE; e->nav_progress = 0; e->nav_suppressed = false;
}

static int navigation_cancel(tp_engine_t *e, tp_emit_t emit, void *context) {
    int steps = 0;
    if (e->nav_axis != NAV_NONE) { emit_navigation(emit, context, e->nav_axis, e->nav_progress, TP_CANCELLED); steps = 1; }
    navigation_reset(e);
    return steps;
}

static bool navigation_has_ids(const tp_engine_t *e, const tp_touches_t *touches, bool subset_only) {
    for (int i = 0; i < touches->count; i++) {
        bool known = false;
        for (int j = 0; j < e->nav_ids_count; j++) if (e->nav_ids[j] == touches->items[i].id) known = true;
        if (!known) return false;
    }
    return subset_only || touches->count == e->nav_ids_count;
}

/// A contact count that can start a navigation gesture.
static bool navigation_count(int count, bool pages, int mission_fingers) {
    return (count == 3 && (pages || mission_fingers == 3)) || (count == 4 && mission_fingers == 4);
}

static void navigation_anchor(tp_engine_t *e, const tp_touches_t *touches) {
    centroid(touches, &e->nav_origin_x, &e->nav_origin_y);
    e->nav_origin_has = true;
    e->nav_ids_count = touches->count;
    for (int i = 0; i < touches->count; i++) e->nav_ids[i] = touches->items[i].id;
}

/// Page swipes use three contacts; Mission Control uses `mission_fingers`
/// (0 when off). Returns the number of steps emitted.
static int navigation_update(tp_engine_t *e, const tp_touches_t *touches, bool pages, int mission_fingers, tp_emit_t emit, void *context) {
    if (touches->count == 0) {
        int steps = 0;
        if (e->nav_axis != NAV_NONE) { emit_navigation(emit, context, e->nav_axis, e->nav_progress, TP_ENDED); steps = 1; }
        navigation_reset(e);
        return steps;
    }
    if (e->nav_suppressed) return 0;
    bool usable = navigation_count(touches->count, pages, mission_fingers);
    if (!e->nav_origin_has) {
        if (usable) navigation_anchor(e, touches);
        return 0;
    }
    if (touches->count != e->nav_ids_count) {
        // A fourth finger landing before any axis was chosen restarts the gesture
        // with four contacts instead of ending it.
        if (e->nav_axis == NAV_NONE && usable && touches->count > e->nav_ids_count) {
            navigation_anchor(e, touches);
            return 0;
        }
        int steps = 0;
        if (e->nav_axis != NAV_NONE) {
            bool lifting = touches->count < e->nav_ids_count && navigation_has_ids(e, touches, true);
            emit_navigation(emit, context, e->nav_axis, e->nav_progress, lifting ? TP_ENDED : TP_CANCELLED);
            steps = 1;
        }
        navigation_reset(e);
        e->nav_suppressed = true;
        return steps;
    }
    if (!navigation_has_ids(e, touches, false)) {
        int steps = navigation_cancel(e, emit, context);
        e->nav_suppressed = true;
        return steps;
    }
    double cx, cy; centroid(touches, &cx, &cy);
    double dx = cx - e->nav_origin_x, dy = cy - e->nav_origin_y;
    int steps = 0;
    if (e->nav_axis == NAV_NONE) {
        if (pages && e->nav_ids_count == 3 && fabs(dx) >= 30 && fabs(dx) > fabs(dy) * 1.5) e->nav_axis = NAV_PAGES;
        else if (mission_fingers == e->nav_ids_count && fabs(dy) >= 30 && fabs(dy) > fabs(dx) * 1.5) e->nav_axis = NAV_MISSION_CONTROL;
        if (e->nav_axis != NAV_NONE) { emit_navigation(emit, context, e->nav_axis, 0, TP_BEGAN); steps++; }
    }
    if (e->nav_axis != NAV_NONE) {
        double updated = clampd((e->nav_axis == NAV_PAGES ? dx : -dy) / 300, -3, 3);
        if (updated != e->nav_progress) {
            e->nav_progress = updated;
            emit_navigation(emit, context, e->nav_axis, updated, TP_CHANGED); steps++;
        }
    }
    return steps;
}

// ---- TrackpadGestureEngine ----

bool tp_engine_hold_deadline(const tp_engine_t *e, double *deadline) {
    if (!e->options.hold_to_drag || e->dragging || e->suppressed || e->peak != 1
        || e->previous.count != 1 || !e->anchor_has) return false;
    *deadline = e->anchor_time + e->options.hold_duration;
    return true;
}

void tp_engine_cancel(tp_engine_t *e, tp_emit_t emit, void *context) {
    navigation_cancel(e, emit, context);
    if (e->dragging) emit_button(emit, context, false);
    if (e->scrolling) emit_scroll(emit, context, 0, 0, TP_CANCELLED);
    if (e->pinching) emit_magnify(emit, context, 0, TP_CANCELLED);
    tp_options_t options = e->options;
    tp_engine_init(e);
    e->options = options;
}

void tp_engine_update(tp_engine_t *e, const tp_touches_t *touches, double time, tp_emit_t emit, void *context) {
    const tp_options_t *o = &e->options;
    bool finite = isfinite(time) && touches->count >= 0 && touches->count <= TP_MAX_TOUCHES;
    for (int i = 0; finite && i < touches->count; i++) finite = isfinite(touches->items[i].x) && isfinite(touches->items[i].y);
    if (!finite || (e->updated && time < e->last_update)) { tp_engine_cancel(e, emit, context); return; }
    e->updated = true; e->last_update = time;

    double scale = 0;
    bool has_scale = pinch_update(e, touches, &scale);
    double pointer_dx = 0, pointer_dy = 0;
    bool has_pointer = pointer_update(e, touches, &pointer_dx, &pointer_dy);

    if (e->previous.count == 0 && touches->count > 0) {
        e->began = time; e->peak = 0; e->travel = 0; e->origins = *touches; e->suppressed = false;
        tp_command_t stop = command(TP_STOP_MOMENTUM); emit(&stop, context);
    }
    for (int i = 0; i < touches->count; i++) {
        const tp_touch_t *point = &touches->items[i];
        const tp_touch_t *origin = find(&e->origins, point->id);
        if (!origin && e->origins.count < TP_MAX_TOUCHES) {
            e->origins.items[e->origins.count++] = *point;
            origin = point;
        }
        if (origin) e->travel = fmax(e->travel, hypot(point->x - origin->x, point->y - origin->y));
    }
    if (touches->count > e->peak) e->peak = touches->count;
    if (e->peak > 1 || e->travel > o->movement_threshold) e->tap_has = false;
    bool pages = o->page_swipes && !o->three_finger_drag;
    int mission = !o->mission_control ? 0 : (o->mission_fingers == 4 ? 4 : (o->three_finger_drag ? 0 : 3));
    if (touches->count > 4 || (touches->count == 4 && mission != 4)
        || (touches->count == 3 && !o->three_finger_drag && mission != 3 && !pages)) e->suppressed = true;
    if (touches->count == 1 && e->previous.count == 1 && !same_ids(touches, &e->previous)) e->suppressed = true;

    if (pages || mission) {
        int steps = e->suppressed ? navigation_cancel(e, emit, context)
                                  : navigation_update(e, touches, pages, mission, emit, context);
        // A navigation contact group never leaks scroll, pointer or lift clicks.
        bool group = navigation_count(touches->count, pages, mission);
        if (group || steps > 0) {
            if (e->scrolling) { emit_scroll(emit, context, 0, 0, TP_CANCELLED); e->scrolling = false; }
            if (e->dragging) { emit_button(emit, context, false); e->dragging = false; }
            if (e->pinching) { emit_magnify(emit, context, 0, TP_CANCELLED); e->pinching = false; }
            e->tap_has = false; e->anchor_has = false;
            if (!group) e->suppressed = true;
            e->previous = *touches;
            return;
        }
    }

    if (e->pinching) {
        bool stable = o->pinch && touches->count == 2 && same_ids(touches, &e->previous);
        int steps; double amount;
        if (stable && has_scale && pinch_changes(e->previous_scale, scale, &steps, &amount)) {
            for (int i = 0; i < steps; i++) emit_magnify(emit, context, amount, TP_CHANGED);
            e->previous_scale = scale;
        } else {
            emit_magnify(emit, context, 0, touches->count < 2 ? TP_ENDED : TP_CANCELLED);
            e->pinching = false;
            e->suppressed = true;
        }
        e->previous = *touches;
        e->anchor_has = false;
        return;
    }

    // Once scrolling starts, latch that gesture. Finger-spacing/angle jitter
    // during a fast flick must not cancel it or discard its momentum.
    if (touches->count == 2) {
        const tp_touch_t *a, *b; ordered_pair(touches, &a, &b);
        double dx = b->x - a->x, dy = b->y - a->y;
        double distance = hypot(dx, dy), angle = atan2(dy, dx);
        if (e->previous.count != 2 || !same_ids(&e->previous, touches)) {
            e->base_has = true; e->base_distance = distance; e->base_angle = angle;
        }
        if (e->base_has && !e->scrolling && !e->suppressed) {
            double rotation = atan2(sin(angle - e->base_angle), cos(angle - e->base_angle));
            double cx, cy, ox, oy; centroid(touches, &cx, &cy); centroid(&e->origins, &ox, &oy);
            double center_travel = hypot(cx - ox, cy - oy);
            double scale_travel = fabs(distance - e->base_distance);
            int steps; double amount;
            if (o->pinch && fabs(rotation) <= 0.2
                && scale_travel > fmax(12, e->base_distance * 0.06) && scale_travel > center_travel * 1.2
                && has_scale && pinch_changes(1, scale, &steps, &amount)) {
                e->pinching = true;
                e->previous_scale = scale;
                e->tap_has = false;
                emit_magnify(emit, context, 0, TP_BEGAN);
                for (int i = 0; i < steps; i++) emit_magnify(emit, context, amount, TP_CHANGED);
                e->previous = *touches;
                e->anchor_has = false;
                return;
            }
            if ((scale_travel > fmax(30, e->base_distance * 0.15) && scale_travel > center_travel * 1.2)
                || (fabs(rotation) > 0.2 && center_travel < o->movement_threshold * 2)) {
                e->suppressed = true;
            }
        }
    } else {
        e->base_has = false;
    }

    if (e->dragging && touches->count != e->drag_contacts) {
        emit_button(emit, context, false); e->dragging = false; e->suppressed = true;
    }
    if (touches->count == 3 && e->previous.count == 3 && !same_ids(touches, &e->previous)) e->suppressed = true;
    // Finger removal cannot turn a system action into a click or scroll.
    if (touches->count < 3 && e->previous.count == 3) e->suppressed = true;
    // Lifting one of four fingers must not turn the remaining three into a drag.
    if (touches->count < 4 && e->previous.count == 4) e->suppressed = true;
    if (e->scrolling && touches->count != 2) {
        emit_scroll(emit, context, 0, 0, TP_ENDED); e->scrolling = false;
    }

    if (touches->count == 0 && e->previous.count > 0) {
        if (!e->suppressed && !e->dragging && time - e->began <= o->tap_duration && e->travel <= o->movement_threshold) {
            if (e->peak == 1 && o->tap_to_click && e->origins.count > 0) {
                double x = e->origins.items[0].x, y = e->origins.items[0].y;
                int count = 1;
                if (e->tap_has && time - e->tap_time <= 0.35 && hypot(x - e->tap_x, y - e->tap_y) <= 30) {
                    count = e->tap_count == 3 ? 1 : e->tap_count + 1;
                }
                e->tap_has = true; e->tap_time = time; e->tap_x = x; e->tap_y = y; e->tap_count = count;
                emit_click(emit, context, TP_LEFT, count);
            } else if (e->peak == 2 && o->two_finger_tap) {
                e->tap_has = false;
                emit_click(emit, context, TP_RIGHT, 1);
            }
        }
        e->previous.count = 0; e->origins.count = 0; e->peak = 0; e->anchor_has = false;
        return;
    }

    if (!e->suppressed && touches->count == 1 && e->peak == 1) {
        const tp_touch_t *point = &touches->items[0];
        if (!e->anchor_has || hypot(point->x - e->anchor_x, point->y - e->anchor_y) > o->movement_threshold) {
            e->anchor_has = true; e->anchor_x = point->x; e->anchor_y = point->y; e->anchor_time = time;
        }
        if (!e->dragging && o->hold_to_drag && time >= e->anchor_time + o->hold_duration) {
            emit_button(emit, context, true); e->dragging = true; e->drag_contacts = 1; e->tap_has = false;
        }
        if (has_pointer) {
            tp_command_t move = command(TP_MOVE); move.dx = pointer_dx; move.dy = pointer_dy; emit(&move, context);
        }
    } else if (!e->suppressed && touches->count == 3 && o->three_finger_drag
               && same_ids(touches, &e->previous) && e->travel > o->movement_threshold) {
        double cx, cy, px, py; centroid(touches, &cx, &cy); centroid(&e->previous, &px, &py);
        double dx = cx - px, dy = cy - py;
        if (fabs(dx) <= 128 && fabs(dy) <= 128 && (dx != 0 || dy != 0)) {
            if (!e->dragging) { emit_button(emit, context, true); e->dragging = true; e->drag_contacts = 3; }
            tp_command_t move = command(TP_MOVE); move.dx = dx; move.dy = dy; emit(&move, context);
        }
    } else if (!e->suppressed && touches->count == 2 && same_ids(touches, &e->previous)) {
        double cx, cy, px, py; centroid(touches, &cx, &cy); centroid(&e->previous, &px, &py);
        double dx = cx - px, dy = cy - py;
        if (fabs(dx) <= 2048 && fabs(dy) <= 2048 && (dx != 0 || dy != 0) && e->travel > o->movement_threshold) {
            emit_scroll(emit, context, dx, dy, e->scrolling ? TP_CHANGED : TP_BEGAN);
            e->scrolling = true;
            e->tap_has = false;
        }
    }
    e->previous = *touches;
    if (e->suppressed || e->peak != 1 || touches->count != 1) e->anchor_has = false;
}

// ---- MotionScaling ----

void tp_scale(const tp_command_t *source, double factor, tp_emit_t emit, void *context) {
    if (!isfinite(factor) || (source->kind != TP_MOVE && source->kind != TP_SCROLL)) { emit(source, context); return; }
    double x = source->dx * factor, y = source->dy * factor;
    tp_command_t scaled = *source;
    if (source->kind != TP_SCROLL) {
        scaled.dx = clampd(x, -128, 128); scaled.dy = clampd(y, -128, 128);
        emit(&scaled, context);
        return;
    }
    // Preserve scaled flick distance without exceeding an individual wire packet.
    double count = ceil(fmax(fabs(x), fabs(y)) / 2048);
    if (!isfinite(count) || count > 16) return;
    int steps = count < 1 ? 1 : (int)count;
    scaled.dx = x / steps; scaled.dy = y / steps;
    if (source->has_interval) scaled.interval_ms = source->interval_ms / steps;
    for (int i = 0; i < steps; i++) {
        tp_command_t part = scaled;
        if (i > 0 && source->phase == TP_BEGAN) part.phase = TP_CHANGED;
        emit(&part, context);
    }
}
