// SPDX-License-Identifier: GPL-3.0-or-later
// Audio engine on top of the PulseAudio client API. Works with PulseAudio and
// with PipeWire (pipewire-pulse).
//
// Routing:
//   real mic --(loopback "voice")--> fboard_sink (null sink) --monitor-->
//   fboard_mic (remapped source, what voice apps record from)
//   sounds: stream "speakers" -> output sink, stream "mic" -> fboard_sink
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <pulse/pulseaudio.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

#define SINK_NAME "fboard_sink"
#define SOURCE_NAME "fboard_mic"
#define CH 2
#define FRAME_BYTES (sizeof(float) * CH)

static pa_threaded_mainloop* ml;
static pa_context* ctx;
static atomic_int connected;

static const pa_sample_spec SPEC = {.format = PA_SAMPLE_FLOAT32LE, .rate = FB_RATE, .channels = CH};

// ------------------------------------------------------------ settings
static double g_speaker_volume = 1.0;
static double g_mic_volume = 1.0;
static int g_norm_enabled = 0;
static double g_norm_target = -23.0;
static int g_norm_dynamic = 0;
static int g_block_voice = 0;
static int g_activation_enabled = 0;
static float* g_activation = NULL;  // stereo
static int64_t g_activation_frames = 0;
static char* g_output_sink = NULL;

// ------------------------------------------------------------ vmic state
static uint32_t mod_null = PA_INVALID_INDEX;
static uint32_t mod_remap = PA_INVALID_INDEX;
static uint32_t mod_voice = PA_INVALID_INDEX;
static uint32_t mod_hear = PA_INVALID_INDEX;
static char* real_mic = NULL;      // resolved real microphone source name
static char* prev_default = NULL;  // default source before we changed it
static int voice_muted = 0;

// ------------------------------------------------------------ mic monitor
static pa_stream* mic_mon = NULL;
static atomic_uint mic_peak_bits;
static int measuring = 0;
static fb_lufs_state measure_lufs;

// ------------------------------------------------------------ playback
typedef struct playback {
  atomic_int refs;
  int id;
  float* buf;  // stereo, decoded so far
  int64_t frames;
  int64_t cap;
  int decode_done;
  int decode_error;
  double duration;
  int64_t start_frame;  // offset of buf[0] in the file (for start_sec)
  int64_t spk_pos, mic_pos;
  int64_t mic_pre;  // activation frames still to write on the mic stream
  pa_stream* spk;
  pa_stream* mic;
  int spk_done, mic_done;
  int spk_draining, mic_draining;
  pa_operation* spk_drain_op;
  pa_operation* mic_drain_op;
  int started;
  int paused;
  int to_spk, to_mic;
  int finished;
  double known_lufs;
  double gain;  // current normalization gain
  fb_lufs_state lufs;
  int64_t lufs_fed;
  atomic_int cancel;
  char* path;
  float out_peak;
} playback;

static playback* cur = NULL;
static atomic_int next_id = 1;
static atomic_uint out_peak_bits;

static void pb_unref(playback* p) {
  if (atomic_fetch_sub(&p->refs, 1) == 1) {
    free(p->buf);
    free(p->path);
    fb_lufs_destroy(&p->lufs);
    free(p);
  }
}

static float bits_to_float(unsigned v) {
  float f;
  memcpy(&f, &v, 4);
  return f;
}
static unsigned float_to_bits(float f) {
  unsigned v;
  memcpy(&v, &f, 4);
  return v;
}

// ------------------------------------------------------------ helpers
static void op_unref(pa_operation* o) {
  if (o) pa_operation_unref(o);
}

static void op_wait(pa_operation* o) {
  if (!o) return;
  while (pa_operation_get_state(o) == PA_OPERATION_RUNNING) pa_threaded_mainloop_wait(ml);
  pa_operation_unref(o);
}

static void success_cb(pa_context* c, int success, void* ud) {
  (void)c;
  if (ud) *(int*)ud = success;
  pa_threaded_mainloop_signal(ml, 0);
}

static void index_cb(pa_context* c, uint32_t idx, void* ud) {
  (void)c;
  *(uint32_t*)ud = idx;
  pa_threaded_mainloop_signal(ml, 0);
}

static uint32_t load_module(const char* name, const char* args) {
  uint32_t idx = PA_INVALID_INDEX;
  op_wait(pa_context_load_module(ctx, name, args, index_cb, &idx));
  return idx;
}

static void unload_module(uint32_t* idx) {
  if (*idx == PA_INVALID_INDEX) return;
  op_wait(pa_context_unload_module(ctx, *idx, success_cb, NULL));
  *idx = PA_INVALID_INDEX;
}

// ------------------------------------------------------------ server info
typedef struct {
  char default_sink[256];
  char default_source[256];
} server_info;

static void server_info_cb(pa_context* c, const pa_server_info* i, void* ud) {
  (void)c;
  server_info* s = ud;
  snprintf(s->default_sink, sizeof(s->default_sink), "%s", i && i->default_sink_name ? i->default_sink_name : "");
  snprintf(s->default_source, sizeof(s->default_source), "%s",
           i && i->default_source_name ? i->default_source_name : "");
  pa_threaded_mainloop_signal(ml, 0);
}

static void get_server_info(server_info* s) {
  memset(s, 0, sizeof(*s));
  op_wait(pa_context_get_server_info(ctx, server_info_cb, s));
}

// ------------------------------------------------------------ context
static void subscribe_cb(pa_context* c, pa_subscription_event_type_t t, uint32_t idx, void* ud) {
  (void)c, (void)idx, (void)ud;
  unsigned fac = t & PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
  unsigned type = t & PA_SUBSCRIPTION_EVENT_TYPE_MASK;
  if (fac == PA_SUBSCRIPTION_EVENT_SERVER ||
      ((fac == PA_SUBSCRIPTION_EVENT_SINK || fac == PA_SUBSCRIPTION_EVENT_SOURCE) &&
       type != PA_SUBSCRIPTION_EVENT_CHANGE))
    fb_emit(FB_EV_DEVICES_CHANGED, 0, 0, 0);
}

static void ctx_state_cb(pa_context* c, void* ud) {
  (void)ud;
  pa_context_state_t s = pa_context_get_state(c);
  if (s == PA_CONTEXT_READY) {
    atomic_store(&connected, 1);
  } else if (s == PA_CONTEXT_FAILED || s == PA_CONTEXT_TERMINATED) {
    if (atomic_exchange(&connected, 0)) fb_emit(FB_EV_AUDIO_STATE, 0, 0, 0);
  }
  pa_threaded_mainloop_signal(ml, 0);
}

static void module_list_cb(pa_context* c, const pa_module_info* i, int eol, void* ud) {
  (void)c;
  if (eol) {
    pa_threaded_mainloop_signal(ml, 0);
    return;
  }
  // Collect stale fboard modules (left behind by a crash).
  if (i->argument && (strstr(i->argument, "fboard_sink") || strstr(i->argument, "fboard_mic"))) {
    uint32_t* list = ud;
    for (int k = 0; k < 15; k++)
      if (list[k] == PA_INVALID_INDEX) {
        list[k] = i->index;
        break;
      }
  }
}

int fb_audio_init(void) {
  if (ml) return atomic_load(&connected) ? 0 : -1;
  ml = pa_threaded_mainloop_new();
  pa_proplist* pl = pa_proplist_new();
  pa_proplist_sets(pl, PA_PROP_APPLICATION_NAME, "fboard");
  pa_proplist_sets(pl, PA_PROP_APPLICATION_ID, "io.github.proshiv85_byte.fboard");
  pa_proplist_sets(pl, PA_PROP_APPLICATION_ICON_NAME, "io.github.proshiv85_byte.fboard");
  ctx = pa_context_new_with_proplist(pa_threaded_mainloop_get_api(ml), "fboard", pl);
  pa_proplist_free(pl);
  pa_context_set_state_callback(ctx, ctx_state_cb, NULL);
  pa_threaded_mainloop_lock(ml);
  pa_threaded_mainloop_start(ml);
  if (pa_context_connect(ctx, NULL, PA_CONTEXT_NOFLAGS, NULL) < 0) {
    pa_threaded_mainloop_unlock(ml);
    return -1;
  }
  for (;;) {
    pa_context_state_t s = pa_context_get_state(ctx);
    if (s == PA_CONTEXT_READY) break;
    if (!PA_CONTEXT_IS_GOOD(s)) {
      pa_threaded_mainloop_unlock(ml);
      return -2;
    }
    pa_threaded_mainloop_wait(ml);
  }
  // Remove leftovers from a previous crash.
  uint32_t stale[16];
  for (int k = 0; k < 16; k++) stale[k] = PA_INVALID_INDEX;
  op_wait(pa_context_get_module_info_list(ctx, module_list_cb, stale));
  for (int k = 15; k >= 0; k--) unload_module(&stale[k]);

  pa_context_set_subscribe_callback(ctx, subscribe_cb, NULL);
  op_wait(pa_context_subscribe(ctx, PA_SUBSCRIPTION_MASK_SINK | PA_SUBSCRIPTION_MASK_SOURCE | PA_SUBSCRIPTION_MASK_SERVER,
                               success_cb, NULL));
  pa_threaded_mainloop_unlock(ml);
  fb_emit(FB_EV_AUDIO_STATE, 1, 0, 0);
  return 0;
}

int fb_audio_connected(void) { return atomic_load(&connected); }

static void stop_locked(void);
static void mic_monitor_stop_locked(void);

void fb_audio_shutdown(void) {
  if (!ml) return;
  pa_threaded_mainloop_lock(ml);
  stop_locked();
  pa_threaded_mainloop_unlock(ml);
  fb_rec_stop();
  fb_vmic_teardown();
  pa_threaded_mainloop_lock(ml);
  mic_monitor_stop_locked();
  pa_context_disconnect(ctx);
  pa_threaded_mainloop_unlock(ml);
  pa_threaded_mainloop_stop(ml);
  pa_context_unref(ctx);
  pa_threaded_mainloop_free(ml);
  ml = NULL;
  ctx = NULL;
}

// ------------------------------------------------------------ device list
typedef struct {
  char* buf;
  size_t len, cap;
} sbuf;

static void sb_add(sbuf* b, const char* s) {
  size_t n = strlen(s);
  if (b->len + n + 1 > b->cap) {
    b->cap = (b->len + n + 1) * 2;
    b->buf = realloc(b->buf, b->cap);
  }
  memcpy(b->buf + b->len, s, n + 1);
  b->len += n;
}

static void sb_str(sbuf* b, const char* s) {
  sb_add(b, "\"");
  char tmp[8];
  for (const unsigned char* p = (const unsigned char*)(s ? s : ""); *p; p++) {
    if (*p == '"' || *p == '\\') {
      tmp[0] = '\\';
      tmp[1] = *p;
      tmp[2] = 0;
    } else if (*p < 0x20) {
      snprintf(tmp, sizeof tmp, "\\u%04x", *p);
    } else {
      tmp[0] = *p;
      tmp[1] = 0;
    }
    sb_add(b, tmp);
  }
  sb_add(b, "\"");
}

typedef struct {
  sbuf* b;
  int first;
} list_ctx;

static void source_list_cb(pa_context* c, const pa_source_info* i, int eol, void* ud) {
  (void)c;
  list_ctx* l = ud;
  if (eol) {
    pa_threaded_mainloop_signal(ml, 0);
    return;
  }
  if (strcmp(i->name, SOURCE_NAME) == 0 || strcmp(i->name, SINK_NAME ".monitor") == 0) return;
  if (!l->first) sb_add(l->b, ",");
  l->first = 0;
  sb_add(l->b, "{\"name\":");
  sb_str(l->b, i->name);
  sb_add(l->b, ",\"desc\":");
  sb_str(l->b, i->description);
  sb_add(l->b, i->monitor_of_sink != PA_INVALID_INDEX ? ",\"monitor\":true}" : ",\"monitor\":false}");
}

static void sink_list_cb(pa_context* c, const pa_sink_info* i, int eol, void* ud) {
  (void)c;
  list_ctx* l = ud;
  if (eol) {
    pa_threaded_mainloop_signal(ml, 0);
    return;
  }
  if (strcmp(i->name, SINK_NAME) == 0) return;
  if (!l->first) sb_add(l->b, ",");
  l->first = 0;
  sb_add(l->b, "{\"name\":");
  sb_str(l->b, i->name);
  sb_add(l->b, ",\"desc\":");
  sb_str(l->b, i->description);
  sb_add(l->b, "}");
}

char* fb_list_devices(void) {
  if (!atomic_load(&connected)) return NULL;
  sbuf b = {0};
  pa_threaded_mainloop_lock(ml);
  server_info si;
  get_server_info(&si);
  sb_add(&b, "{\"sources\":[");
  list_ctx l = {&b, 1};
  op_wait(pa_context_get_source_info_list(ctx, source_list_cb, &l));
  sb_add(&b, "],\"sinks\":[");
  l.first = 1;
  op_wait(pa_context_get_sink_info_list(ctx, sink_list_cb, &l));
  sb_add(&b, "],\"default_source\":");
  // While fboard is the default, report the real default to the UI.
  sb_str(&b, (prev_default && strcmp(si.default_source, SOURCE_NAME) == 0) ? prev_default : si.default_source);
  sb_add(&b, ",\"default_sink\":");
  sb_str(&b, si.default_sink);
  sb_add(&b, "}");
  pa_threaded_mainloop_unlock(ml);
  return b.buf;
}

// ------------------------------------------------------------ mic monitor
static void mic_mon_read_cb(pa_stream* s, size_t nbytes, void* ud) {
  (void)nbytes, (void)ud;
  const void* data;
  size_t n;
  while (pa_stream_readable_size(s) > 0) {
    if (pa_stream_peek(s, &data, &n) < 0) return;
    if (n == 0) break;
    if (data) {
      const float* f = data;
      size_t cnt = n / sizeof(float);
      float pk = bits_to_float(atomic_load(&mic_peak_bits));
      for (size_t k = 0; k < cnt; k++) {
        float v = fabsf(f[k]);
        if (v > pk) pk = v;
      }
      atomic_store(&mic_peak_bits, float_to_bits(pk));
      if (measuring) fb_lufs_feed(&measure_lufs, f, (int64_t)(cnt / CH));
    }
    pa_stream_drop(s);
  }
}

static void mic_monitor_stop_locked(void) {
  if (mic_mon) {
    pa_stream_set_read_callback(mic_mon, NULL, NULL);
    pa_stream_disconnect(mic_mon);
    pa_stream_unref(mic_mon);
    mic_mon = NULL;
  }
}

static void mic_monitor_start_locked(const char* source) {
  mic_monitor_stop_locked();
  pa_proplist* pl = pa_proplist_new();
  pa_proplist_sets(pl, PA_PROP_MEDIA_ROLE, "abstract");
  pa_proplist_sets(pl, "node.passive", "true");
  mic_mon = pa_stream_new_with_proplist(ctx, "Microphone level", &SPEC, NULL, pl);
  pa_proplist_free(pl);
  pa_stream_set_read_callback(mic_mon, mic_mon_read_cb, NULL);
  pa_buffer_attr a = {.maxlength = (uint32_t)-1, .fragsize = FB_RATE / 25 * FRAME_BYTES};
  pa_stream_connect_record(mic_mon, source, &a, PA_STREAM_ADJUST_LATENCY | PA_STREAM_DONT_MOVE);
}

// ------------------------------------------------------------ vmic
// Fully asynchronous so it can run from the mainloop thread too.
static void voice_input_cb(pa_context* c, const pa_sink_input_info* i, int eol, void* ud) {
  if (eol || !i) return;
  if (i->owner_module == mod_voice && mod_voice != PA_INVALID_INDEX)
    op_unref(pa_context_set_sink_input_mute(c, i->index, (int)(intptr_t)ud, NULL, NULL));
}

static void apply_voice_mute_locked(int mute) {
  if (mod_voice == PA_INVALID_INDEX || mute == voice_muted) return;
  voice_muted = mute;
  op_unref(pa_context_get_sink_input_info_list(ctx, voice_input_cb, (void*)(intptr_t)mute));
}

// Mute the voice while something plays on the mic and "block voice" is on.
static void update_voice_block_locked(void) {
  int want = g_block_voice && cur && !cur->finished && !cur->paused && cur->to_mic;
  apply_voice_mute_locked(want);
}

int fb_vmic_setup(const char* mic_source, int set_default) {
  if (!atomic_load(&connected)) return -1;
  fb_vmic_teardown();
  pa_threaded_mainloop_lock(ml);
  server_info si;
  get_server_info(&si);
  free(real_mic);
  if (mic_source && mic_source[0])
    real_mic = strdup(mic_source);
  else
    real_mic = strdup(strcmp(si.default_source, SOURCE_NAME) == 0 && prev_default ? prev_default : si.default_source);

  char args[1024];
  snprintf(args, sizeof args,
           "sink_name=" SINK_NAME " sink_properties='device.description=\"fboard Mixer\" device.icon_name=\"audio-card\"' rate=%d channels=2",
           FB_RATE);
  mod_null = load_module("module-null-sink", args);
  if (mod_null == PA_INVALID_INDEX) {
    pa_threaded_mainloop_unlock(ml);
    return -2;
  }
  mod_remap = load_module("module-remap-source", "master=" SINK_NAME ".monitor source_name=" SOURCE_NAME
                                                 " source_properties='device.description=\"fboard Microphone\" "
                                                 "device.icon_name=\"audio-input-microphone\"'");
  if (mod_remap == PA_INVALID_INDEX) {
    unload_module(&mod_null);
    pa_threaded_mainloop_unlock(ml);
    return -3;
  }
  if (real_mic && real_mic[0]) {
    snprintf(args, sizeof args,
             "source=%s sink=" SINK_NAME " latency_msec=20 source_dont_move=true sink_dont_move=true "
             "sink_input_properties='media.name=\"fboard voice\"' source_output_properties='media.name=\"fboard voice\"'",
             real_mic);
    mod_voice = load_module("module-loopback", args);
    voice_muted = 0;
    mic_monitor_start_locked(real_mic);
  }
  if (set_default) {
    free(prev_default);
    prev_default = strdup(si.default_source);
    if (strcmp(prev_default, SOURCE_NAME) == 0) {
      free(prev_default);
      prev_default = real_mic ? strdup(real_mic) : NULL;
    }
    op_wait(pa_context_set_default_source(ctx, SOURCE_NAME, success_cb, NULL));
  }
  update_voice_block_locked();
  pa_threaded_mainloop_unlock(ml);
  return 0;
}

int fb_vmic_active(void) { return mod_null != PA_INVALID_INDEX; }

void fb_vmic_teardown(void) {
  if (!ml || !atomic_load(&connected)) return;
  pa_threaded_mainloop_lock(ml);
  // Streams pointing to the null sink are killed with it; stop playback first.
  if (cur && cur->mic) {
    pa_stream_set_write_callback(cur->mic, NULL, NULL);
    pa_stream_set_state_callback(cur->mic, NULL, NULL);
    if (cur->mic_drain_op) {
      pa_operation_cancel(cur->mic_drain_op);
      pa_operation_unref(cur->mic_drain_op);
      cur->mic_drain_op = NULL;
    }
    pa_stream_disconnect(cur->mic);
    pa_stream_unref(cur->mic);
    cur->mic = NULL;
    cur->mic_done = 1;
  }
  if (prev_default && mod_null != PA_INVALID_INDEX) {
    server_info si;
    get_server_info(&si);
    if (strcmp(si.default_source, SOURCE_NAME) == 0)
      op_wait(pa_context_set_default_source(ctx, prev_default, success_cb, NULL));
  }
  free(prev_default);
  prev_default = NULL;
  mic_monitor_stop_locked();
  unload_module(&mod_hear);
  unload_module(&mod_voice);
  unload_module(&mod_remap);
  unload_module(&mod_null);
  pa_threaded_mainloop_unlock(ml);
}

void fb_set_block_voice(int on) {
  g_block_voice = on;
  if (!ml) return;
  pa_threaded_mainloop_lock(ml);
  update_voice_block_locked();
  pa_threaded_mainloop_unlock(ml);
}

int fb_set_hear_myself(int on) {
  if (!atomic_load(&connected)) return -1;
  pa_threaded_mainloop_lock(ml);
  unload_module(&mod_hear);
  int r = 0;
  if (on && real_mic && real_mic[0]) {
    char args[1024];
    if (g_output_sink && g_output_sink[0])
      snprintf(args, sizeof args,
               "source=%s sink=%s latency_msec=20 source_dont_move=true "
               "sink_input_properties='media.name=\"fboard hear myself\"'",
               real_mic, g_output_sink);
    else
      snprintf(args, sizeof args,
               "source=%s latency_msec=20 source_dont_move=true "
               "sink_input_properties='media.name=\"fboard hear myself\"'",
               real_mic);
    mod_hear = load_module("module-loopback", args);
    if (mod_hear == PA_INVALID_INDEX) r = -2;
  }
  pa_threaded_mainloop_unlock(ml);
  return r;
}

int fb_set_default_source(const char* source) {
  if (!atomic_load(&connected) || !source || !source[0]) return -1;
  int ok = 0;
  pa_threaded_mainloop_lock(ml);
  op_wait(pa_context_set_default_source(ctx, source, success_cb, &ok));
  pa_threaded_mainloop_unlock(ml);
  return ok ? 0 : -2;
}

void fb_set_output_sink(const char* sink) {
  free(g_output_sink);
  g_output_sink = sink && sink[0] ? strdup(sink) : NULL;
}

// ------------------------------------------------------------ playback
static double target_gain(playback* p) {
  if (!g_norm_enabled) return 1.0;
  double l = p->known_lufs;
  if (isnan(l) || g_norm_dynamic) {
    l = fb_lufs_value(&p->lufs);
    if (!isfinite(l)) return p->gain;  // keep previous until we know more
  }
  if (!isfinite(l)) return 1.0;
  double g = pow(10.0, (g_norm_target - l) / 20.0);
  if (g > 10.0) g = 10.0;  // +20 dB max
  return g;
}

static void finish_deferred(pa_mainloop_api* a, void* ud);

static void maybe_finish(playback* p) {
  if (p->finished) return;
  if ((p->spk_done || !p->spk) && (p->mic_done || !p->mic)) {
    p->finished = 1;
    atomic_fetch_add(&p->refs, 1);
    pa_mainloop_api_once(pa_threaded_mainloop_get_api(ml), finish_deferred, p);
  }
}

static void drain_cb(pa_stream* s, int success, void* ud) {
  (void)success;
  playback* p = ud;
  if (s == p->spk) {
    p->spk_done = 1;
    if (p->spk_drain_op) {
      pa_operation_unref(p->spk_drain_op);
      p->spk_drain_op = NULL;
    }
  } else if (s == p->mic) {
    p->mic_done = 1;
    if (p->mic_drain_op) {
      pa_operation_unref(p->mic_drain_op);
      p->mic_drain_op = NULL;
    }
  }
  maybe_finish(p);
}

static void write_cb(pa_stream* s, size_t nbytes, void* ud) {
  playback* p = ud;
  if (p != cur || p->finished) return;
  int is_mic = (s == p->mic);
  if (is_mic ? p->mic_draining : p->spk_draining) return;
  int64_t* pos = is_mic ? &p->mic_pos : &p->spk_pos;

  void* vout;
  size_t sz = nbytes;
  if (pa_stream_begin_write(s, &vout, &sz) < 0 || !vout) return;
  float* out = vout;
  int64_t want = (int64_t)(sz / FRAME_BYTES);
  int64_t done = 0;

  // Voice-activation prefix on the mic only.
  if (is_mic && p->mic_pre > 0 && g_activation) {
    int64_t off = g_activation_frames - p->mic_pre;
    int64_t n = p->mic_pre < want ? p->mic_pre : want;
    float g = (float)(p->to_mic ? 1.0 : 0.0);
    for (int64_t i = 0; i < n * CH; i++) out[i] = g_activation[off * CH + i] * g;
    p->mic_pre -= n;
    done = n;
  }

  int64_t avail = p->frames - *pos;
  if (avail <= 0 && p->decode_done && done == 0) {
    pa_stream_cancel_write(s);
    if (is_mic) {
      p->mic_draining = 1;
      p->mic_drain_op = pa_stream_drain(s, drain_cb, p);
    } else {
      p->spk_draining = 1;
      p->spk_drain_op = pa_stream_drain(s, drain_cb, p);
    }
    return;
  }

  // Normalization gain follows the speakers cursor; feed the analyzer with the
  // next 6 seconds (dynamic adjustment).
  if (!is_mic && g_norm_enabled && (isnan(p->known_lufs) || g_norm_dynamic)) {
    int64_t upto = *pos + 6 * FB_RATE;
    if (upto > p->frames) upto = p->frames;
    if (upto > p->lufs_fed) {
      fb_lufs_feed(&p->lufs, p->buf + p->lufs_fed * CH, upto - p->lufs_fed);
      p->lufs_fed = upto;
    }
  }
  double tg = target_gain(p);
  if (tg != p->gain) p->gain = p->gain + (tg - p->gain) * 0.2;  // smooth
  if (!g_norm_enabled) p->gain = 1.0;

  double route = is_mic ? (p->to_mic ? (g_norm_enabled ? 1.0 : g_mic_volume) : 0.0)
                        : (p->to_spk ? g_speaker_volume : 0.0);
  float g = (float)(route * p->gain);
  int64_t n = want - done;
  if (n > avail) n = avail > 0 ? avail : 0;
  float pk = 0;
  const float* src = p->buf + *pos * CH;
  for (int64_t i = 0; i < n * CH; i++) {
    float v = src[i] * g;
    if (v > 1.f) v = 1.f;
    if (v < -1.f) v = -1.f;
    out[done * CH + i] = v;
    float a = fabsf(v);
    if (a > pk) pk = a;
  }
  *pos += n;
  done += n;
  if (done == 0) {
    // Decoder is behind: write a little silence to keep the stream alive.
    int64_t sil = FB_RATE / 100;
    if (sil > want) sil = want;
    memset(out, 0, sil * FRAME_BYTES);
    done = sil;
  }
  if (!is_mic || !p->spk) {
    float prev = bits_to_float(atomic_load(&out_peak_bits));
    if (pk > prev) atomic_store(&out_peak_bits, float_to_bits(pk));
  }
  pa_stream_write(s, out, done * FRAME_BYTES, NULL, 0, PA_SEEK_RELATIVE);
}

static void stream_state_cb(pa_stream* s, void* ud) {
  playback* p = ud;
  if (p != cur) return;
  pa_stream_state_t st = pa_stream_get_state(s);
  if (st == PA_STREAM_READY && p->started) {
    op_unref(pa_stream_cork(s, p->paused, NULL, NULL));
  } else if (st == PA_STREAM_FAILED) {
    // Treat a failed stream as finished so the other one can complete.
    if (s == p->spk) p->spk_done = 1;
    if (s == p->mic) p->mic_done = 1;
    maybe_finish(p);
  }
}

static pa_stream* make_stream(playback* p, const char* name, const char* device) {
  pa_proplist* pl = pa_proplist_new();
  pa_proplist_sets(pl, PA_PROP_MEDIA_ROLE, "event");
  pa_proplist_sets(pl, PA_PROP_MEDIA_NAME, name);
  pa_stream* s = pa_stream_new_with_proplist(ctx, name, &SPEC, NULL, pl);
  pa_proplist_free(pl);
  if (!s) return NULL;
  pa_stream_set_write_callback(s, write_cb, p);
  pa_stream_set_state_callback(s, stream_state_cb, p);
  pa_buffer_attr a;
  a.maxlength = (uint32_t)-1;
  a.tlength = (uint32_t)(FB_RATE * 40 / 1000 * FRAME_BYTES);
  a.prebuf = (uint32_t)-1;
  a.minreq = (uint32_t)(FB_RATE * 10 / 1000 * FRAME_BYTES);
  a.fragsize = (uint32_t)-1;
  pa_stream_flags_t fl = PA_STREAM_ADJUST_LATENCY | PA_STREAM_START_CORKED;
  if (device) fl |= PA_STREAM_DONT_MOVE;
  if (pa_stream_connect_playback(s, device, &a, fl, NULL, NULL) < 0) {
    pa_stream_unref(s);
    return NULL;
  }
  return s;
}

static void release_stream(pa_stream** s, pa_operation** op) {
  if (*op) {
    pa_operation_cancel(*op);
    pa_operation_unref(*op);
    *op = NULL;
  }
  if (*s) {
    pa_stream_set_write_callback(*s, NULL, NULL);
    pa_stream_set_state_callback(*s, NULL, NULL);
    pa_stream_disconnect(*s);
    pa_stream_unref(*s);
    *s = NULL;
  }
}

// Drops the current playback (ml lock held).
static void stop_locked(void) {
  playback* p = cur;
  if (!p) return;
  cur = NULL;
  atomic_store(&p->cancel, 1);
  release_stream(&p->spk, &p->spk_drain_op);
  release_stream(&p->mic, &p->mic_drain_op);
  if (!p->finished) {
    p->finished = 1;
    fb_emit(FB_EV_PLAYBACK_FINISHED, p->id, 0, 0);
  }
  update_voice_block_locked();
  pb_unref(p);
}

static void finish_deferred(pa_mainloop_api* a, void* ud) {
  (void)a;
  playback* p = ud;
  if (cur == p) {
    cur = NULL;
    release_stream(&p->spk, &p->spk_drain_op);
    release_stream(&p->mic, &p->mic_drain_op);
    fb_emit(FB_EV_PLAYBACK_FINISHED, p->id, 1, 0);
    update_voice_block_locked();
    pb_unref(p);  // owner reference
  }
  pb_unref(p);  // deferred reference
}

static void cork_ready(pa_stream* s, int cork) {
  if (s && pa_stream_get_state(s) == PA_STREAM_READY) op_unref(pa_stream_cork(s, cork, NULL, NULL));
}

static void start_streams_locked(playback* p) {
  if (p->started || p != cur) return;
  p->started = 1;
  cork_ready(p->spk, p->paused);
  cork_ready(p->mic, p->paused);
}

static void append_frames(playback* p, const float* data, int64_t frames, int ch) {
  if (p->frames + frames > p->cap) {
    int64_t ncap = p->cap ? p->cap * 2 : FB_RATE * 8;
    while (ncap < p->frames + frames) ncap *= 2;
    p->buf = realloc(p->buf, sizeof(float) * ncap * CH);
    p->cap = ncap;
  }
  float* dst = p->buf + p->frames * CH;
  if (ch == 1) {
    for (int64_t i = 0; i < frames; i++) dst[i * 2] = dst[i * 2 + 1] = data[i];
  } else {
    memcpy(dst, data, sizeof(float) * frames * CH);
  }
  p->frames += frames;
}

typedef struct {
  playback* p;
  int ch;
} dec_sink_ctx;

static void dec_sink(void* user, const float* data, int64_t frames) {
  dec_sink_ctx* c = user;
  pa_threaded_mainloop_lock(ml);
  append_frames(c->p, data, frames, c->ch);
  // Start once we have 300 ms buffered (or the whole thing).
  if (c->p->frames >= FB_RATE * 3 / 10) start_streams_locked(c->p);
  pa_threaded_mainloop_unlock(ml);
}

static void* decoder_thread(void* arg) {
  playback* p = arg;
  fb_decoder* d = fb_decoder_open(p->path);
  if (!d) {
    pa_threaded_mainloop_lock(ml);
    p->decode_error = 1;
    p->decode_done = 1;
    if (cur == p) {
      fb_emit(FB_EV_PLAYBACK_ERROR, p->id, 0, 0);
      stop_locked();
    }
    pa_threaded_mainloop_unlock(ml);
    pb_unref(p);
    return NULL;
  }
  pa_threaded_mainloop_lock(ml);
  p->duration = fb_decoder_duration(d);
  pa_threaded_mainloop_unlock(ml);
  if (p->start_frame > 0) fb_decoder_seek(d, (double)p->start_frame / FB_RATE);
  dec_sink_ctx sc = {p, fb_decoder_channels(d)};
  while (!atomic_load(&p->cancel)) {
    int64_t r = fb_decoder_read(d, dec_sink, &sc);
    if (r <= 0) break;
  }
  fb_decoder_close(d);
  pa_threaded_mainloop_lock(ml);
  p->decode_done = 1;
  if (p->duration <= 0) p->duration = (double)(p->start_frame + p->frames) / FB_RATE;
  start_streams_locked(p);
  pa_threaded_mainloop_unlock(ml);
  pb_unref(p);
  return NULL;
}

static playback* new_playback(int to_spk, int to_mic, double lufs) {
  playback* p = calloc(1, sizeof(*p));
  atomic_store(&p->refs, 1);
  p->id = atomic_fetch_add(&next_id, 1);
  p->to_spk = to_spk;
  p->to_mic = to_mic;
  p->known_lufs = lufs;
  p->gain = 1.0;
  p->duration = -1;
  fb_lufs_init(&p->lufs, CH);
  if (g_norm_enabled && !isnan(lufs) && !g_norm_dynamic) p->gain = target_gain(p);
  return p;
}

// Sets up streams for p and makes it current (ml lock held).
static int attach_locked(playback* p) {
  stop_locked();
  cur = p;
  p->spk = make_stream(p, "fboard (speakers)", g_output_sink);
  if (mod_null != PA_INVALID_INDEX) {
    p->mic = make_stream(p, "fboard (microphone)", SINK_NAME);
    if (p->to_mic && g_activation_enabled && g_activation) p->mic_pre = g_activation_frames;
  }
  if (!p->spk && !p->mic) {
    cur = NULL;
    return -3;
  }
  update_voice_block_locked();
  return 0;
}

int32_t fb_play(const char* path, int to_speakers, int to_mic, double start_sec, double lufs) {
  if (!atomic_load(&connected)) return -1;
  playback* p = new_playback(to_speakers, to_mic, lufs);
  p->path = strdup(path);
  if (start_sec > 0) p->start_frame = (int64_t)(start_sec * FB_RATE);
  pa_threaded_mainloop_lock(ml);
  int r = attach_locked(p);
  if (r < 0) {
    pa_threaded_mainloop_unlock(ml);
    pb_unref(p);
    return r;
  }
  atomic_fetch_add(&p->refs, 1);  // decoder thread reference
  pthread_t th;
  pthread_attr_t at;
  pthread_attr_init(&at);
  pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
  if (pthread_create(&th, &at, decoder_thread, p) != 0) {
    pb_unref(p);
    stop_locked();
    pa_threaded_mainloop_unlock(ml);
    return -4;
  }
  pthread_attr_destroy(&at);
  int id = p->id;
  pa_threaded_mainloop_unlock(ml);
  return id;
}

int32_t fb_play_buffer(const float* data, int64_t frames, int32_t channels, int to_speakers, int to_mic) {
  if (!atomic_load(&connected)) return -1;
  playback* p = new_playback(to_speakers, to_mic, NAN);
  append_frames(p, data, frames, channels);
  p->decode_done = 1;
  p->duration = (double)frames / FB_RATE;
  if (g_norm_enabled) {
    fb_lufs_feed(&p->lufs, p->buf, p->frames);
    p->lufs_fed = p->frames;
    p->known_lufs = fb_lufs_value(&p->lufs);
    p->gain = target_gain(p);
  }
  pa_threaded_mainloop_lock(ml);
  int r = attach_locked(p);
  if (r < 0) {
    pa_threaded_mainloop_unlock(ml);
    pb_unref(p);
    return r;
  }
  start_streams_locked(p);
  int id = p->id;
  pa_threaded_mainloop_unlock(ml);
  return id;
}

void fb_stop(void) {
  if (!ml) return;
  pa_threaded_mainloop_lock(ml);
  stop_locked();
  pa_threaded_mainloop_unlock(ml);
}

void fb_pause(int paused) {
  if (!ml) return;
  pa_threaded_mainloop_lock(ml);
  playback* p = cur;
  if (p && p->paused != paused) {
    p->paused = paused;
    if (p->started) {
      cork_ready(p->spk, paused);
      cork_ready(p->mic, paused);
    }
    update_voice_block_locked();
  }
  pa_threaded_mainloop_unlock(ml);
}

void fb_seek(double sec) {
  if (!ml) return;
  pa_threaded_mainloop_lock(ml);
  playback* p = cur;
  if (p) {
    int64_t f = (int64_t)(sec * FB_RATE) - p->start_frame;
    if (f < 0) f = 0;
    if (p->decode_done && f > p->frames) f = p->frames;
    p->spk_pos = p->mic_pos = f;
    p->mic_pre = 0;
    if (p->spk && !p->spk_draining && pa_stream_get_state(p->spk) == PA_STREAM_READY) op_unref(pa_stream_flush(p->spk, NULL, NULL));
    if (p->mic && !p->mic_draining && pa_stream_get_state(p->mic) == PA_STREAM_READY) op_unref(pa_stream_flush(p->mic, NULL, NULL));
  }
  pa_threaded_mainloop_unlock(ml);
}

void fb_set_routing(int to_speakers, int to_mic) {
  if (!ml) return;
  pa_threaded_mainloop_lock(ml);
  if (cur) {
    cur->to_spk = to_speakers;
    cur->to_mic = to_mic;
    update_voice_block_locked();
  }
  pa_threaded_mainloop_unlock(ml);
}

void fb_set_speaker_volume(double v) { g_speaker_volume = v; }
void fb_set_mic_volume(double v) { g_mic_volume = v; }

void fb_set_normalization(int enabled, double target, int dynamic) {
  g_norm_enabled = enabled;
  g_norm_target = target;
  g_norm_dynamic = dynamic;
}

static void make_builtin_activation(void) {
  // 180 ms of loud band-limited noise with short fades.
  int64_t n = FB_RATE * 18 / 100;
  g_activation = malloc(sizeof(float) * n * CH);
  uint32_t seed = 12345;
  float lp = 0;
  for (int64_t i = 0; i < n; i++) {
    seed = seed * 1664525u + 1013904223u;
    float w = ((seed >> 9) / (float)(1 << 23)) * 2.f - 1.f;
    lp = lp * 0.6f + w * 0.4f;
    float env = 1.f;
    if (i < FB_RATE / 200) env = i / (float)(FB_RATE / 200);
    if (n - i < FB_RATE / 200) env = (n - i) / (float)(FB_RATE / 200);
    g_activation[i * 2] = g_activation[i * 2 + 1] = lp * 0.8f * env;
  }
  g_activation_frames = n;
}

void fb_set_activation_sound(int enabled, const char* path) {
  g_activation_enabled = enabled;
  if (ml) pa_threaded_mainloop_lock(ml);
  free(g_activation);
  g_activation = NULL;
  g_activation_frames = 0;
  if (path && path[0]) {
    float* d;
    int64_t f;
    int32_t ch;
    if (fb_decode(path, &d, &f, &ch) == 0) {
      g_activation = malloc(sizeof(float) * f * CH);
      for (int64_t i = 0; i < f; i++) {
        g_activation[i * 2] = d[i * ch];
        g_activation[i * 2 + 1] = d[i * ch + (ch > 1 ? 1 : 0)];
      }
      g_activation_frames = f;
      free(d);
    }
  }
  if (!g_activation) make_builtin_activation();
  if (ml) pa_threaded_mainloop_unlock(ml);
}

static int stream_latency_frames(pa_stream* s) {
  pa_usec_t lat = 0;
  int neg = 0;
  if (!s || pa_stream_get_latency(s, &lat, &neg) < 0) return 0;
  return neg ? 0 : (int)(lat * FB_RATE / 1000000);
}

void fb_get_status(fb_status* out) {
  memset(out, 0, sizeof(*out));
  out->duration = -1;
  out->mic_peak = bits_to_float(atomic_exchange(&mic_peak_bits, 0));
  out->output_peak = bits_to_float(atomic_exchange(&out_peak_bits, 0));
  if (!ml) return;
  pa_threaded_mainloop_lock(ml);
  playback* p = cur;
  if (p) {
    out->state = p->paused ? 2 : 1;
    out->id = p->id;
    pa_stream* s = p->spk ? p->spk : p->mic;
    int64_t pos = (s == p->spk ? p->spk_pos : p->mic_pos) - stream_latency_frames(s);
    if (pos < 0) pos = 0;
    out->position = (double)(pos + p->start_frame) / FB_RATE;
    out->duration = p->decode_done ? (double)(p->start_frame + p->frames) / FB_RATE : p->duration;
    out->to_speakers = p->to_spk;
    out->to_mic = p->to_mic;
  }
  pa_threaded_mainloop_unlock(ml);
}

// ------------------------------------------------------------ notifications
typedef struct {
  float* data;
  int64_t frames;
  int64_t pos;
} notif;

static void notif_state_cb(pa_stream* s, void* ud);

static void notif_drain_cb(pa_stream* s, int success, void* ud) {
  (void)success;
  notif* n = ud;
  pa_stream_set_write_callback(s, NULL, NULL);
  pa_stream_set_state_callback(s, NULL, NULL);
  pa_stream_disconnect(s);
  pa_stream_unref(s);
  free(n->data);
  free(n);
}

static void notif_write_cb(pa_stream* s, size_t nbytes, void* ud) {
  notif* n = ud;
  int64_t want = (int64_t)(nbytes / FRAME_BYTES);
  int64_t left = n->frames - n->pos;
  if (left <= 0) {
    pa_stream_set_write_callback(s, NULL, NULL);
    op_unref(pa_stream_drain(s, notif_drain_cb, n));
    return;
  }
  if (want > left) want = left;
  pa_stream_write(s, n->data + n->pos * CH, want * FRAME_BYTES, NULL, 0, PA_SEEK_RELATIVE);
  n->pos += want;
}

static void notif_state_cb(pa_stream* s, void* ud) {
  pa_stream_state_t st = pa_stream_get_state(s);
  if (st == PA_STREAM_FAILED) notif_drain_cb(s, 0, ud);
}

static void tone(float* d, int64_t at, int64_t len, double freq, float amp) {
  for (int64_t i = 0; i < len; i++) {
    double env = 1.0;
    int64_t fade = FB_RATE / 200;
    if (i < fade) env = (double)i / fade;
    if (len - i < fade) env = (double)(len - i) / fade;
    float v = (float)(sin(2 * M_PI * freq * i / FB_RATE) * amp * env);
    d[(at + i) * 2] += v;
    d[(at + i) * 2 + 1] += v;
  }
}

void fb_play_notification(int kind, const char* path) {
  if (!atomic_load(&connected)) return;
  notif* n = calloc(1, sizeof(*n));
  if (path && path[0]) {
    float* d;
    int64_t f;
    int32_t ch;
    if (fb_decode(path, &d, &f, &ch) == 0) {
      n->data = malloc(sizeof(float) * f * CH);
      for (int64_t i = 0; i < f; i++) {
        n->data[i * 2] = d[i * ch];
        n->data[i * 2 + 1] = d[i * ch + (ch > 1 ? 1 : 0)];
      }
      n->frames = f;
      free(d);
    }
  }
  if (!n->data) {
    int64_t beep = FB_RATE / 10, gap = FB_RATE / 20;
    n->frames = beep * 2 + gap;
    n->data = calloc(n->frames * CH, sizeof(float));
    float a = (float)(0.35 * g_speaker_volume);
    switch (kind) {
      case 1:
        tone(n->data, 0, beep, 880, a);
        tone(n->data, beep + gap, beep, 880, a);
        break;
      case 2:
        tone(n->data, 0, beep, 660, a);
        tone(n->data, beep + gap, beep, 990, a);
        break;
      case 3:
        tone(n->data, 0, beep, 990, a);
        tone(n->data, beep + gap, beep, 660, a);
        break;
      default:
        tone(n->data, 0, beep * 2, 880, a);
        break;
    }
  }
  pa_threaded_mainloop_lock(ml);
  pa_proplist* pl = pa_proplist_new();
  pa_proplist_sets(pl, PA_PROP_MEDIA_ROLE, "event");
  pa_stream* s = pa_stream_new_with_proplist(ctx, "fboard notification", &SPEC, NULL, pl);
  pa_proplist_free(pl);
  pa_stream_set_write_callback(s, notif_write_cb, n);
  pa_stream_set_state_callback(s, notif_state_cb, n);
  pa_stream_connect_playback(s, g_output_sink, NULL, 0, NULL, NULL);
  pa_threaded_mainloop_unlock(ml);
}

// ------------------------------------------------------------ voice measure
void fb_measure_voice_start(void) {
  if (!ml) return;
  pa_threaded_mainloop_lock(ml);
  fb_lufs_destroy(&measure_lufs);
  fb_lufs_init(&measure_lufs, CH);
  measuring = 1;
  pa_threaded_mainloop_unlock(ml);
}

double fb_measure_voice_stop(void) {
  if (!ml) return -HUGE_VAL;
  pa_threaded_mainloop_lock(ml);
  measuring = 0;
  double v = fb_lufs_value(&measure_lufs);
  pa_threaded_mainloop_unlock(ml);
  return v;
}

// ------------------------------------------------------------ recorder
static pa_stream* rec = NULL;
static FILE* rec_file = NULL;
static int64_t rec_frames = 0;
static int64_t rec_max = 0;
static double rec_gain = 1.0;
static atomic_uint rec_peak_bits;

static void rec_stop_deferred(pa_mainloop_api* a, void* ud) {
  (void)a, (void)ud;
  if (!rec) return;
  pa_stream_set_read_callback(rec, NULL, NULL);
  pa_stream_disconnect(rec);
  pa_stream_unref(rec);
  rec = NULL;
  if (rec_file) fflush(rec_file);
  fb_emit(FB_EV_RECORDER_LIMIT, 0, 0, rec_frames);
}

static void rec_read_cb(pa_stream* s, size_t nbytes, void* ud) {
  (void)nbytes, (void)ud;
  const void* data;
  size_t n;
  while (pa_stream_readable_size(s) > 0) {
    if (pa_stream_peek(s, &data, &n) < 0) return;
    if (n == 0) break;
    int64_t frames = (int64_t)(n / FRAME_BYTES);
    if (rec_max > 0 && rec_frames + frames > rec_max) frames = rec_max - rec_frames;
    float buf[4096];
    float pk = bits_to_float(atomic_load(&rec_peak_bits));
    for (int64_t off = 0; off < frames * CH; off += 4096) {
      int64_t cnt = frames * CH - off;
      if (cnt > 4096) cnt = 4096;
      for (int64_t k = 0; k < cnt; k++) {
        float v = data ? ((const float*)data)[off + k] * (float)rec_gain : 0.f;
        buf[k] = v;
        if (fabsf(v) > pk) pk = fabsf(v);
      }
      if (rec_file) fwrite(buf, sizeof(float), (size_t)cnt, rec_file);
    }
    atomic_store(&rec_peak_bits, float_to_bits(pk));
    rec_frames += frames;
    pa_stream_drop(s);
    if (rec_max > 0 && rec_frames >= rec_max) {
      pa_mainloop_api_once(pa_threaded_mainloop_get_api(ml), rec_stop_deferred, NULL);
      return;
    }
  }
}

int fb_rec_start(const char* source, double max_seconds, const char* temp_path) {
  if (!atomic_load(&connected)) return -1;
  fb_rec_stop();
  rec_file = fopen(temp_path, "wb");
  if (!rec_file) return -errno;
  pa_threaded_mainloop_lock(ml);
  char src[512];
  if (source && source[0]) {
    snprintf(src, sizeof src, "%s", source);
  } else {
    server_info si;
    get_server_info(&si);
    snprintf(src, sizeof src, "%s.monitor", g_output_sink ? g_output_sink : si.default_sink);
  }
  rec_frames = 0;
  rec_max = max_seconds > 0 ? (int64_t)(max_seconds * FB_RATE) : 0;
  pa_proplist* pl = pa_proplist_new();
  pa_proplist_sets(pl, PA_PROP_MEDIA_ROLE, "production");
  rec = pa_stream_new_with_proplist(ctx, "fboard recorder", &SPEC, NULL, pl);
  pa_proplist_free(pl);
  pa_stream_set_read_callback(rec, rec_read_cb, NULL);
  pa_buffer_attr a = {.maxlength = (uint32_t)-1, .fragsize = FB_RATE / 20 * FRAME_BYTES};
  int r = pa_stream_connect_record(rec, src, &a, PA_STREAM_ADJUST_LATENCY | PA_STREAM_DONT_MOVE);
  if (r < 0) {
    pa_stream_unref(rec);
    rec = NULL;
    fclose(rec_file);
    rec_file = NULL;
  }
  pa_threaded_mainloop_unlock(ml);
  return r < 0 ? -2 : 0;
}

int64_t fb_rec_stop(void) {
  if (!ml) return 0;
  pa_threaded_mainloop_lock(ml);
  if (rec) {
    pa_stream_set_read_callback(rec, NULL, NULL);
    pa_stream_disconnect(rec);
    pa_stream_unref(rec);
    rec = NULL;
  }
  if (rec_file) {
    fclose(rec_file);
    rec_file = NULL;
  }
  int64_t f = rec_frames;
  pa_threaded_mainloop_unlock(ml);
  return f;
}

int fb_rec_active(void) { return rec != NULL; }
double fb_rec_seconds(void) { return (double)rec_frames / FB_RATE; }
float fb_rec_peak(void) { return bits_to_float(atomic_exchange(&rec_peak_bits, 0)); }
void fb_rec_set_gain(double v) { rec_gain = v; }
