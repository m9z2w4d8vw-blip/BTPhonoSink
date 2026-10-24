/*
 * BTPSBuild.h - GENERATED from the bluetoothd binary pulled off the phone. Do not hand-edit.
 *
 * Why this exists: the tweak hooks functions by offset, and offsets are only valid for ONE build of the daemon.
 * Before hooking anything the tweak checks (1) the image UUID and (2) the first four instruction words at each
 * target against the values below, and refuses to hook on any mismatch. A wrong guess is then a log line,
 * not a crash loop of the Bluetooth daemon.
 *
 * Analysed build : 10196720 bytes, arm64e, sha256 e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6
 * LC_UUID        : 5491BA47-B5AE-3D44-9536-B30161DF1E90
 *
 * Every entry is the address of the function's `pacibsp` (its real entry). The first version of this table pointed one
 * instruction too far (just past pacibsp), which on arm64e leaves the return address double-signed and crashes
 * on the first call. Each entry was confirmed by finding the function that contains its own log message.
 */
#pragma once
#include <stdint.h>
#include <stddef.h>

#define BTPS_BUILD_SHA256 "e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6"
#define BTPS_BUILD_UUID   "5491BA47-B5AE-3D44-9536-B30161DF1E90"

static const uint8_t BTPS_EXPECTED_UUID[16] = { 0x54, 0x91, 0xba, 0x47, 0xb5, 0xae, 0x3d, 0x44, 0x95, 0x36, 0xb3, 0x01, 0x61, 0xdf, 0x1e, 0x90 };

enum { BTPS_H_REGISTER, BTPS_H_ADVERTISE, BTPS_H_SETCONFIGIND, BTPS_H_ACCEPT_SBC, BTPS_H_PUBLISH, BTPS_N_HOOKS };

typedef struct {
    const char *name;
    uintptr_t   entry;     /* offset of the function entry (pacibsp) from the image base */
    uint32_t    sig[4];    /* first four instruction words of that function */
} btps_target_t;

static const btps_target_t BTPS_TARGETS[BTPS_N_HOOKS] = {
    { "AVDTP_RegisterMultipoint", 0x00cecf0, { 0xd503237f, 0xd102c3ff, 0xa9056ffc, 0xa90667fa } },  /* pacibsp ; sub sp, sp, #176 ; stp x28, x27, [sp, #80] */
    { "advertise_A2DP_source", 0x044df14, { 0xd503237f, 0xa9ba6ffc, 0xa90167fa, 0xa9025ff8 } },  /* pacibsp ; stp x28, x27, [sp, #-96]! ; stp x26, x25, [sp, #16] */
    { "SetConfigInd_handler", 0x037ae68, { 0xd503237f, 0xd10303ff, 0xa9066ffc, 0xa90767fa } },  /* pacibsp ; sub sp, sp, #192 ; stp x28, x27, [sp, #96] */
    { "SetConfig_accept_SBC", 0x03b03b4, { 0xd503237f, 0xd102c3ff, 0x6d0423e9, 0xa9056ffc } },  /* pacibsp ; sub sp, sp, #176 ; stp d9, d8, [sp, #64] */
    { "publish_audio_device", 0x0376e4c, { 0xd503237f, 0xd104c3ff, 0xa90d6ffc, 0xa90e67fa } },  /* pacibsp ; sub sp, sp, #304 ; stp x28, x27, [sp, #208] */
};
