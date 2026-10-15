// Small, allocation-free mailbox between touch sampling and LVGL. Callers
// serialize access. Coalesce motion, but preserve every press/release edge.
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct { bool pressed; int16_t x, y; } ui_pointer_t;
enum { UI_POINTER_CAPACITY = 32 };
typedef struct {
    ui_pointer_t items[UI_POINTER_CAPACITY], last;
    unsigned head, count;
} ui_pointer_queue_t;

static inline bool ui_pointer_push(ui_pointer_queue_t *q, ui_pointer_t p) {
    if (q->count) {
        unsigned tail = (q->head + q->count - 1) % UI_POINTER_CAPACITY;
        if (q->items[tail].pressed == p.pressed) {
            q->items[tail] = p;
            return true;
        }
    } else if (q->last.pressed == p.pressed && q->last.x == p.x && q->last.y == p.y) {
        return true;
    }
    if (q->count == UI_POINTER_CAPACITY) {
        // A stalled UI must first release its old target. Drop the backlog
        // rather than replaying dozens of stale actions when it recovers.
        q->head = 0;
        q->count = 1;
        q->items[0] = (ui_pointer_t){ false, q->last.x, q->last.y };
        q->items[q->count++] = p;
        return false;
    }
    q->items[(q->head + q->count++) % UI_POINTER_CAPACITY] = p;
    return true;
}

static inline ui_pointer_t ui_pointer_pop(ui_pointer_queue_t *q) {
    if (q->count) {
        q->last = q->items[q->head];
        q->head = (q->head + 1) % UI_POINTER_CAPACITY;
        q->count--;
    }
    return q->last;
}
