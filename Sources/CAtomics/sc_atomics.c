// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

#include "sc_atomics.h"
#include <stdatomic.h>
#include <stdlib.h>

struct sc_atomic_ptr { _Atomic(void *) value; };

sc_atomic_ptr *sc_atomic_ptr_create(void) {
    sc_atomic_ptr *cell = malloc(sizeof *cell);
    atomic_init(&cell->value, NULL);
    return cell;
}
void sc_atomic_ptr_destroy(sc_atomic_ptr *cell) { free(cell); }
void *sc_atomic_ptr_load(sc_atomic_ptr *cell) {
    return atomic_load_explicit(&cell->value, memory_order_acquire);
}
void *sc_atomic_ptr_exchange(sc_atomic_ptr *cell, void *value) {
    return atomic_exchange_explicit(&cell->value, value, memory_order_acq_rel);
}

struct sc_flags { int32_t count; _Atomic(int32_t) values[]; };

sc_flags *sc_flags_create(int32_t count) {
    if (count < 0) count = 0;
    sc_flags *flags = malloc(sizeof *flags + sizeof(_Atomic(int32_t)) * (size_t)count);
    flags->count = count;
    for (int32_t i = 0; i < count; i++) atomic_init(&flags->values[i], 0);
    return flags;
}
void sc_flags_destroy(sc_flags *flags) { free(flags); }
void sc_flags_set(sc_flags *flags, int32_t index) {
    if (index < 0 || index >= flags->count) return;
    atomic_store_explicit(&flags->values[index], 1, memory_order_release);
}
int32_t sc_flags_get(sc_flags *flags, int32_t index) {
    if (index < 0 || index >= flags->count) return 0;
    return atomic_load_explicit(&flags->values[index], memory_order_acquire);
}

struct sc_counter { _Atomic(int64_t) value; };

sc_counter *sc_counter_create(void) {
    sc_counter *counter = malloc(sizeof *counter);
    atomic_init(&counter->value, 0);
    return counter;
}
void sc_counter_destroy(sc_counter *counter) { free(counter); }
void sc_counter_increment(sc_counter *counter) {
    atomic_fetch_add_explicit(&counter->value, 1, memory_order_relaxed);
}
int64_t sc_counter_get(sc_counter *counter) {
    return atomic_load_explicit(&counter->value, memory_order_relaxed);
}
