// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

#ifndef SC_ATOMICS_H
#define SC_ATOMICS_H

#include <stdint.h>

#pragma clang assume_nonnull begin

/// A pointer-sized cell read by the audio thread and swapped by the main thread.
typedef struct sc_atomic_ptr sc_atomic_ptr;
sc_atomic_ptr *sc_atomic_ptr_create(void);
void sc_atomic_ptr_destroy(sc_atomic_ptr *cell);
void *_Nullable sc_atomic_ptr_load(sc_atomic_ptr *cell);
/// Stores `value` and returns the previous value.
void *_Nullable sc_atomic_ptr_exchange(sc_atomic_ptr *cell, void *_Nullable value);

/// A fixed array of 0/1 flags (one per render stage). Out-of-range indexes are ignored / read as 0.
typedef struct sc_flags sc_flags;
sc_flags *sc_flags_create(int32_t count);
void sc_flags_destroy(sc_flags *flags);
void sc_flags_set(sc_flags *flags, int32_t index);
int32_t sc_flags_get(sc_flags *flags, int32_t index);

/// A monotonically increasing counter.
typedef struct sc_counter sc_counter;
sc_counter *sc_counter_create(void);
void sc_counter_destroy(sc_counter *counter);
void sc_counter_increment(sc_counter *counter);
int64_t sc_counter_get(sc_counter *counter);

#pragma clang assume_nonnull end

#endif
