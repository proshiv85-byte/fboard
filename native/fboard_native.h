// fboard native layer: audio engine (PulseAudio/PipeWire + FFmpeg), loudness
// analysis, global input (evdev / X11) and key injection (uinput).
// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef FBOARD_NATIVE_H
#define FBOARD_NATIVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FB_EXPORT __attribute__((visibility("default")))

// ---------------------------------------------------------------- events ---
// Events are delivered from native threads through a single callback.
enum {
  FB_EV_PLAYBACK_FINISHED = 1,  // a = play id, b = 1 if it ended naturally
  FB_EV_PLAYBACK_ERROR = 2,     // a = play id
  FB_EV_KEY = 3,                // a = evdev code, b = value (0 up, 1 down), c = modifier mask
  FB_EV_AUDIO_STATE = 4,        // a = 1 connected / 0 disconnected
  FB_EV_DEVICES_CHANGED = 5,
  FB_EV_RECORDER_LIMIT = 6,     // recording hit the max time and stopped
  FB_EV_INPUT_ERROR = 7,        // a = backend, b = errno
};

typedef void (*fb_event_cb)(int32_t type, int32_t a, int32_t b, int64_t c);
FB_EXPORT void fb_set_event_callback(fb_event_cb cb);
FB_EXPORT void fb_free(void* p);

// ------------------------------------------------------------ media files ---
typedef struct {
  double duration;      // seconds
  int32_t sample_rate;  // original
  int32_t channels;     // original
  int64_t size;         // bytes
  char format[32];      // short container/codec name (e.g. "MP3")
  char title[256];
  char artist[256];
} fb_media_info;

// Returns 0 on success.
FB_EXPORT int fb_probe(const char* path, fb_media_info* out);
// Decodes the whole file to interleaved float, 48 kHz, 1 or 2 channels.
// *out must be released with fb_free.
FB_EXPORT int fb_decode(const char* path, float** out, int64_t* frames, int32_t* channels);
// Encodes interleaved float (48 kHz) to a file. format: "wav", "mp3", "m4a",
// "ogg", "opus", "flac". Returns 0 on success.
FB_EXPORT int fb_encode(const char* path, const char* format, const float* data, int64_t frames,
                        int32_t channels);
// Integrated loudness (EBU R128 / BS.1770) of 48 kHz interleaved float, LUFS.
// Returns -HUGE_VAL for silence.
FB_EXPORT double fb_loudness(const float* data, int64_t frames, int32_t channels);
// Decodes + measures a file. Returns 0 on success.
FB_EXPORT int fb_analyze(const char* path, double* lufs, double* peak);

// ---------------------------------------------------------- audio engine ---
FB_EXPORT int fb_audio_init(void);
FB_EXPORT void fb_audio_shutdown(void);
FB_EXPORT int fb_audio_connected(void);

// JSON: {"sources":[{"name","desc","monitor":bool}], "sinks":[{"name","desc"}],
// "default_source":"", "default_sink":""}. Release with fb_free.
FB_EXPORT char* fb_list_devices(void);

// Virtual microphone. mic_source: real microphone (NULL/"" = system default).
// set_default: make the fboard microphone the system default input while running.
FB_EXPORT int fb_vmic_setup(const char* mic_source, int set_default);
FB_EXPORT void fb_vmic_teardown(void);
FB_EXPORT int fb_vmic_active(void);
FB_EXPORT void fb_set_block_voice(int on);
FB_EXPORT int fb_set_hear_myself(int on);
FB_EXPORT void fb_set_output_sink(const char* sink);  // NULL/"" = default
FB_EXPORT int fb_set_default_source(const char* source);

// Playback. Only one sound plays at a time (like Soundpad).
// lufs: known loudness of the file, or NaN if unknown.
// Returns a play id (>0) or a negative error code.
FB_EXPORT int32_t fb_play(const char* path, int to_speakers, int to_mic, double start_sec, double lufs);
FB_EXPORT int32_t fb_play_buffer(const float* data, int64_t frames, int32_t channels, int to_speakers,
                                 int to_mic);
FB_EXPORT void fb_stop(void);
FB_EXPORT void fb_pause(int paused);
FB_EXPORT void fb_seek(double sec);
FB_EXPORT void fb_set_routing(int to_speakers, int to_mic);
FB_EXPORT void fb_set_speaker_volume(double linear);
FB_EXPORT void fb_set_mic_volume(double linear);  // used when normalization is off
FB_EXPORT void fb_set_normalization(int enabled, double target_lufs, int dynamic);
FB_EXPORT void fb_set_activation_sound(int enabled, const char* path);  // path NULL = builtin

typedef struct {
  int32_t state;  // 0 stopped, 1 playing, 2 paused
  int32_t id;
  double position;
  double duration;  // -1 while unknown
  int32_t to_speakers;
  int32_t to_mic;
  float mic_peak;     // peak of the real microphone (0..1)
  float output_peak;  // peak of what we are playing (0..1)
} fb_status;
FB_EXPORT void fb_get_status(fb_status* out);

// Short notification sound on speakers only. kind: 0 beep, 1 double beep,
// 2 rising, 3 falling. path overrides the builtin tone when not NULL/"".
FB_EXPORT void fb_play_notification(int kind, const char* path);

// Voice measurement (records the real microphone).
FB_EXPORT void fb_measure_voice_start(void);
FB_EXPORT double fb_measure_voice_stop(void);  // LUFS

// Recorder: records "what you hear" (monitor of the output) or a source.
FB_EXPORT int fb_rec_start(const char* source, double max_seconds, const char* temp_path);
FB_EXPORT int64_t fb_rec_stop(void);  // frames recorded (stereo, 48 kHz)
FB_EXPORT int fb_rec_active(void);
FB_EXPORT double fb_rec_seconds(void);
FB_EXPORT float fb_rec_peak(void);
FB_EXPORT void fb_rec_set_gain(double linear);

// --------------------------------------------------------------- input ---
// Modifier mask bits
#define FB_MOD_LCTRL 0x01
#define FB_MOD_RCTRL 0x02
#define FB_MOD_LSHIFT 0x04
#define FB_MOD_RSHIFT 0x08
#define FB_MOD_LALT 0x10
#define FB_MOD_RALT 0x20
#define FB_MOD_LMETA 0x40
#define FB_MOD_RMETA 0x80

// evdev backend. Returns 0 on success, -errno otherwise.
FB_EXPORT int fb_evdev_start(void);
FB_EXPORT void fb_evdev_stop(void);
FB_EXPORT int fb_evdev_device_count(void);
// When block is on, keyboards are grabbed and hotkeys in the table are
// swallowed; everything else is re-emitted through uinput.
FB_EXPORT int fb_evdev_set_block(int on);
// Hotkey table used for blocking: pairs of (mask, code). sided = 0 means the
// mask is compared without distinguishing left/right modifiers.
FB_EXPORT void fb_evdev_set_table(const int32_t* masks, const int32_t* codes, int32_t n, int sided);

// X11 backend (XGrabKey/XGrabButton). Only reports registered keys.
FB_EXPORT int fb_x11_start(void);
FB_EXPORT void fb_x11_stop(void);
FB_EXPORT void fb_x11_set_table(const int32_t* masks, const int32_t* codes, int32_t n);

// Active window (X11 only). Returns 0 on success.
FB_EXPORT int fb_x11_active_window(char* wm_class, int32_t len, int32_t* pid, int32_t* fullscreen);

// uinput key injection. Returns 0 on success, -errno otherwise.
FB_EXPORT int fb_uinput_open(void);
FB_EXPORT void fb_uinput_close(void);
FB_EXPORT int fb_uinput_key(int32_t code, int32_t value);

#ifdef __cplusplus
}
#endif
#endif
