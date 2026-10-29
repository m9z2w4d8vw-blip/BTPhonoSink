/* Worker-only freshness policy. No receive-thread work or shared ABI change. */
#pragma once
#include <stdint.h>

typedef struct {
    uint64_t generation, media_counter, heartbeat_counter;
    uint64_t media_ms, heartbeat_ms, render_ms;
    uint32_t render_counter;
    unsigned media_seen, heartbeat_seen, render_seen, playing;
} BTPSV882Health;

static inline void btps_v882_health_reset(BTPSV882Health *h,uint64_t generation,
                                         uint64_t media,uint64_t heartbeat) {
    *h=(BTPSV882Health){0};h->generation=generation;
    h->media_counter=media;h->heartbeat_counter=heartbeat;
}
static inline void btps_v882_health_sample(BTPSV882Health *h,uint64_t media,
                                          uint64_t heartbeat,uint64_t now) {
    if(media!=h->media_counter) {h->media_counter=media;h->media_ms=now;h->media_seen=1;}
    if(heartbeat!=h->heartbeat_counter) {h->heartbeat_counter=heartbeat;h->heartbeat_ms=now;h->heartbeat_seen=1;}
}
static inline void btps_v882_health_render(BTPSV882Health *h,uint32_t generation,
                                          uint32_t rendered,unsigned playing,uint64_t now) {
    if(!(h->generation&1u) || (uint32_t)h->generation!=generation) return;
    h->playing=playing;
    if(playing && rendered!=h->render_counter) {h->render_ms=now;h->render_seen=1;}
    h->render_counter=rendered;
    if(!playing) h->render_seen=0;
}
static inline int btps_v882_health_ready(const BTPSV882Health *h,int connected,uint64_t now) {
    return connected && (h->generation&1u) && h->playing &&
        h->media_seen && h->heartbeat_seen && h->render_seen &&
        now>=h->media_ms && now-h->media_ms<=1500u &&
        now>=h->heartbeat_ms && now-h->heartbeat_ms<=1000u &&
        now>=h->render_ms && now-h->render_ms<=1500u;
}
