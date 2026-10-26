/* Offline-testable 880 Hz diagnostic PCM generator. Not an SBC decoder. */
#pragma once
#include <stddef.h>
#include <stdint.h>
int btps_v74_make_tone(uint8_t *out, size_t capacity);
