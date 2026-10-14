// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef FBOARD_INTERNAL_H
#define FBOARD_INTERNAL_H

#include "fboard_native.h"

#define FB_RATE 48000

void fb_emit(int32_t type, int32_t a, int32_t b, int64_t c);

// Streaming decoder
typedef struct fb_decoder fb_decoder;
typedef void (*fb_frames_sink)(void* user, const float* data, int64_t frames);
fb_decoder* fb_decoder_open(const char* path);
void fb_decoder_close(fb_decoder* d);
int fb_decoder_channels(fb_decoder* d);
double fb_decoder_duration(fb_decoder* d);
int fb_decoder_seek(fb_decoder* d, double sec);
int64_t fb_decoder_read(fb_decoder* d, fb_frames_sink sink, void* user);

// Incremental loudness
typedef struct {
  int channels;
  double z[2][4];
  double acc;
  int acc_n;
  double* blocks;
  int nblocks;
  int capblocks;
} fb_lufs_state;
void fb_lufs_init(fb_lufs_state* s, int channels);
void fb_lufs_feed(fb_lufs_state* s, const float* data, int64_t frames);
double fb_lufs_value(const fb_lufs_state* s);
void fb_lufs_destroy(fb_lufs_state* s);

// uinput (shared by evdev re-emission and auto keys)
int fb_uinput_emit_raw(int type, int code, int value);

#endif
