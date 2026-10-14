// SPDX-License-Identifier: GPL-3.0-or-later
// Media decoding/encoding with FFmpeg and BS.1770 loudness measurement.
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "internal.h"

// ------------------------------------------------------------------ events
static fb_event_cb g_event_cb = NULL;

void fb_set_event_callback(fb_event_cb cb) { g_event_cb = cb; }

void fb_emit(int32_t type, int32_t a, int32_t b, int64_t c) {
  fb_event_cb cb = g_event_cb;
  if (cb) cb(type, a, b, c);
}

void fb_free(void* p) { free(p); }

__attribute__((constructor)) static void quiet_ffmpeg(void) { av_log_set_level(AV_LOG_FATAL); }

// ------------------------------------------------------------------- probe
static void copy_tag(AVDictionary* m, const char* key, char* dst, size_t n) {
  AVDictionaryEntry* e = av_dict_get(m, key, NULL, AV_DICT_IGNORE_SUFFIX);
  if (e && e->value) {
    snprintf(dst, n, "%s", e->value);
  }
}

int fb_probe(const char* path, fb_media_info* out) {
  memset(out, 0, sizeof(*out));
  struct stat st;
  if (stat(path, &st) == 0) out->size = st.st_size;
  AVFormatContext* fmt = NULL;
  if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return -1;
  if (avformat_find_stream_info(fmt, NULL) < 0) {
    avformat_close_input(&fmt);
    return -2;
  }
  int si = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  if (si < 0) {
    avformat_close_input(&fmt);
    return -3;
  }
  AVStream* s = fmt->streams[si];
  out->sample_rate = s->codecpar->sample_rate;
  out->channels = s->codecpar->ch_layout.nb_channels;
  if (s->duration != AV_NOPTS_VALUE && s->duration > 0)
    out->duration = s->duration * av_q2d(s->time_base);
  else if (fmt->duration != AV_NOPTS_VALUE)
    out->duration = fmt->duration / (double)AV_TIME_BASE;

  // Human readable format: prefer codec name for raw-ish containers.
  const AVCodecDescriptor* cd = avcodec_descriptor_get(s->codecpar->codec_id);
  const char* name = fmt->iformat->name;
  if (strstr(name, "mp3")) name = "MP3";
  else if (strstr(name, "wav")) name = "WAV";
  else if (strstr(name, "flac")) name = "FLAC";
  else if (strstr(name, "ogg")) name = (cd && strcmp(cd->name, "opus") == 0) ? "OPUS" : "OGG";
  else if (strstr(name, "mp4") || strstr(name, "m4a")) name = "M4A";
  else if (strstr(name, "matroska") || strstr(name, "webm")) name = "WEBM";
  else if (strstr(name, "aac")) name = "AAC";
  else if (strstr(name, "asf")) name = "WMA";
  snprintf(out->format, sizeof(out->format), "%s", name);
  for (char* p = out->format; *p; p++)
    if (*p >= 'a' && *p <= 'z') *p -= 32;

  copy_tag(fmt->metadata, "title", out->title, sizeof(out->title));
  copy_tag(fmt->metadata, "artist", out->artist, sizeof(out->artist));
  if (!out->title[0]) copy_tag(s->metadata, "title", out->title, sizeof(out->title));
  if (!out->artist[0]) copy_tag(s->metadata, "artist", out->artist, sizeof(out->artist));
  avformat_close_input(&fmt);
  return 0;
}

// ------------------------------------------------------------- decoding
struct fb_decoder {
  AVFormatContext* fmt;
  AVCodecContext* dec;
  SwrContext* swr;
  AVPacket* pkt;
  AVFrame* frame;
  int stream;
  int channels;  // output channels (1 or 2)
  int eof;
  double duration;
};

fb_decoder* fb_decoder_open(const char* path) {
  fb_decoder* d = calloc(1, sizeof(*d));
  if (avformat_open_input(&d->fmt, path, NULL, NULL) < 0) goto fail;
  if (avformat_find_stream_info(d->fmt, NULL) < 0) goto fail;
  const AVCodec* codec = NULL;
  d->stream = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
  if (d->stream < 0 || !codec) goto fail;
  AVStream* s = d->fmt->streams[d->stream];
  d->dec = avcodec_alloc_context3(codec);
  avcodec_parameters_to_context(d->dec, s->codecpar);
  if (avcodec_open2(d->dec, codec, NULL) < 0) goto fail;
  if (s->duration != AV_NOPTS_VALUE && s->duration > 0)
    d->duration = s->duration * av_q2d(s->time_base);
  else if (d->fmt->duration != AV_NOPTS_VALUE)
    d->duration = d->fmt->duration / (double)AV_TIME_BASE;
  else
    d->duration = -1;

  int in_ch = d->dec->ch_layout.nb_channels;
  d->channels = in_ch == 1 ? 1 : 2;
  AVChannelLayout out_layout;
  av_channel_layout_default(&out_layout, d->channels);
  if (d->dec->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC)
    av_channel_layout_default(&d->dec->ch_layout, in_ch);
  if (swr_alloc_set_opts2(&d->swr, &out_layout, AV_SAMPLE_FMT_FLT, FB_RATE, &d->dec->ch_layout,
                          d->dec->sample_fmt, d->dec->sample_rate, 0, NULL) < 0)
    goto fail;
  if (swr_init(d->swr) < 0) goto fail;
  d->pkt = av_packet_alloc();
  d->frame = av_frame_alloc();
  return d;
fail:
  fb_decoder_close(d);
  return NULL;
}

int fb_decoder_channels(fb_decoder* d) { return d->channels; }
double fb_decoder_duration(fb_decoder* d) { return d->duration; }

void fb_decoder_close(fb_decoder* d) {
  if (!d) return;
  if (d->frame) av_frame_free(&d->frame);
  if (d->pkt) av_packet_free(&d->pkt);
  if (d->swr) swr_free(&d->swr);
  if (d->dec) avcodec_free_context(&d->dec);
  if (d->fmt) avformat_close_input(&d->fmt);
  free(d);
}

int fb_decoder_seek(fb_decoder* d, double sec) {
  int64_t ts = (int64_t)(sec * AV_TIME_BASE);
  if (av_seek_frame(d->fmt, -1, ts, AVSEEK_FLAG_BACKWARD) < 0) return -1;
  avcodec_flush_buffers(d->dec);
  swr_init(d->swr);
  d->eof = 0;
  return 0;
}

// Decodes the next chunk. Calls sink with converted frames. Returns number of
// frames produced, 0 at end of stream, <0 on error.
int64_t fb_decoder_read(fb_decoder* d, fb_frames_sink sink, void* user) {
  for (;;) {
    int r = avcodec_receive_frame(d->dec, d->frame);
    if (r == 0) {
      int max_out = swr_get_out_samples(d->swr, d->frame->nb_samples);
      float* buf = malloc(sizeof(float) * (size_t)max_out * d->channels + 64);
      uint8_t* outp[1] = {(uint8_t*)buf};
      int n = swr_convert(d->swr, outp, max_out, (const uint8_t**)d->frame->extended_data,
                          d->frame->nb_samples);
      av_frame_unref(d->frame);
      if (n > 0) sink(user, buf, n);
      free(buf);
      if (n > 0) return n;
      continue;
    }
    if (r == AVERROR_EOF) {
      // Flush resampler
      int max_out = swr_get_out_samples(d->swr, 0);
      if (max_out > 0) {
        float* buf = malloc(sizeof(float) * (size_t)max_out * d->channels + 64);
        uint8_t* outp[1] = {(uint8_t*)buf};
        int n = swr_convert(d->swr, outp, max_out, NULL, 0);
        if (n > 0) sink(user, buf, n);
        free(buf);
        if (n > 0) return n;
      }
      return 0;
    }
    if (r != AVERROR(EAGAIN)) return -1;
    if (d->eof) {
      avcodec_send_packet(d->dec, NULL);
      continue;
    }
    r = av_read_frame(d->fmt, d->pkt);
    if (r < 0) {
      d->eof = 1;
      avcodec_send_packet(d->dec, NULL);
      continue;
    }
    if (d->pkt->stream_index == d->stream) avcodec_send_packet(d->dec, d->pkt);
    av_packet_unref(d->pkt);
  }
}

typedef struct {
  float* data;
  int64_t frames;
  int64_t cap;
  int ch;
} grow_buf;

static void grow_sink(void* user, const float* data, int64_t frames) {
  grow_buf* g = user;
  if (g->frames + frames > g->cap) {
    int64_t ncap = g->cap ? g->cap * 2 : FB_RATE * 4;
    while (ncap < g->frames + frames) ncap *= 2;
    g->data = realloc(g->data, sizeof(float) * (size_t)ncap * g->ch);
    g->cap = ncap;
  }
  memcpy(g->data + g->frames * g->ch, data, sizeof(float) * (size_t)frames * g->ch);
  g->frames += frames;
}

int fb_decode(const char* path, float** out, int64_t* frames, int32_t* channels) {
  fb_decoder* d = fb_decoder_open(path);
  if (!d) return -1;
  grow_buf g = {0};
  g.ch = d->channels;
  int64_t r;
  while ((r = fb_decoder_read(d, grow_sink, &g)) > 0) {
  }
  fb_decoder_close(d);
  if (r < 0 && g.frames == 0) {
    free(g.data);
    return -2;
  }
  *out = g.data;
  *frames = g.frames;
  *channels = g.ch;
  return 0;
}

// ------------------------------------------------------------- encoding
static int encode_write(AVCodecContext* c, AVFormatContext* oc, AVStream* st, AVFrame* f, AVPacket* pkt) {
  int r = avcodec_send_frame(c, f);
  if (r < 0) return r;
  while ((r = avcodec_receive_packet(c, pkt)) == 0) {
    av_packet_rescale_ts(pkt, c->time_base, st->time_base);
    pkt->stream_index = st->index;
    av_interleaved_write_frame(oc, pkt);
  }
  return (r == AVERROR(EAGAIN) || r == AVERROR_EOF) ? 0 : r;
}

int fb_encode(const char* path, const char* format, const float* data, int64_t frames, int32_t channels) {
  enum AVCodecID cid;
  const char* muxer;
  int64_t bitrate = 0;
  if (strcmp(format, "wav") == 0) {
    cid = AV_CODEC_ID_PCM_S16LE;
    muxer = "wav";
  } else if (strcmp(format, "mp3") == 0) {
    cid = AV_CODEC_ID_MP3;
    muxer = "mp3";
    bitrate = 192000;
  } else if (strcmp(format, "m4a") == 0) {
    cid = AV_CODEC_ID_AAC;
    muxer = "ipod";
    bitrate = 192000;
  } else if (strcmp(format, "ogg") == 0) {
    cid = AV_CODEC_ID_VORBIS;
    muxer = "ogg";
    bitrate = 192000;
  } else if (strcmp(format, "opus") == 0) {
    cid = AV_CODEC_ID_OPUS;
    muxer = "ogg";
    bitrate = 128000;
  } else if (strcmp(format, "flac") == 0) {
    cid = AV_CODEC_ID_FLAC;
    muxer = "flac";
  } else {
    return -1;
  }
  const AVCodec* codec = NULL;
  if (cid == AV_CODEC_ID_MP3) codec = avcodec_find_encoder_by_name("libmp3lame");
  if (cid == AV_CODEC_ID_VORBIS) codec = avcodec_find_encoder_by_name("libvorbis");
  if (cid == AV_CODEC_ID_OPUS) codec = avcodec_find_encoder_by_name("libopus");
  if (!codec) codec = avcodec_find_encoder(cid);
  if (!codec) return -2;

  AVFormatContext* oc = NULL;
  if (avformat_alloc_output_context2(&oc, NULL, muxer, path) < 0 || !oc) return -3;
  AVStream* st = avformat_new_stream(oc, NULL);
  AVCodecContext* c = avcodec_alloc_context3(codec);
  av_channel_layout_default(&c->ch_layout, channels);
  c->sample_rate = FB_RATE;
  c->bit_rate = bitrate;
  c->time_base = (AVRational){1, FB_RATE};
  // Pick a sample format the encoder supports, preferring float planar.
  const enum AVSampleFormat* fmts = NULL;
  int nfmts = 0;
#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(61, 13, 100)
  avcodec_get_supported_config(c, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, (const void**)&fmts, &nfmts);
#else
  fmts = codec->sample_fmts;
  while (fmts && fmts[nfmts] != AV_SAMPLE_FMT_NONE) nfmts++;
#endif
  c->sample_fmt = fmts && nfmts > 0 ? fmts[0] : AV_SAMPLE_FMT_FLTP;
  for (int i = 0; fmts && i < nfmts; i++)
    if (fmts[i] == AV_SAMPLE_FMT_FLTP) c->sample_fmt = AV_SAMPLE_FMT_FLTP;
  if (cid == AV_CODEC_ID_FLAC) c->sample_fmt = AV_SAMPLE_FMT_S16;
  if (oc->oformat->flags & AVFMT_GLOBALHEADER) c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  int ret = -4;
  if (avcodec_open2(c, codec, NULL) < 0) goto done;
  avcodec_parameters_from_context(st->codecpar, c);
  st->time_base = c->time_base;
  if (!(oc->oformat->flags & AVFMT_NOFILE) && avio_open(&oc->pb, path, AVIO_FLAG_WRITE) < 0) goto done;
  if (avformat_write_header(oc, NULL) < 0) goto done;

  SwrContext* swr = NULL;
  AVChannelLayout layout;
  av_channel_layout_default(&layout, channels);
  swr_alloc_set_opts2(&swr, &c->ch_layout, c->sample_fmt, FB_RATE, &layout, AV_SAMPLE_FMT_FLT, FB_RATE, 0, NULL);
  swr_init(swr);
  int fsize = c->frame_size > 0 ? c->frame_size : 1024;
  AVFrame* f = av_frame_alloc();
  AVPacket* pkt = av_packet_alloc();
  int64_t pts = 0;
  for (int64_t pos = 0; pos < frames; pos += fsize) {
    int n = (int)((frames - pos) < fsize ? (frames - pos) : fsize);
    f->nb_samples = n;
    f->format = c->sample_fmt;
    av_channel_layout_copy(&f->ch_layout, &c->ch_layout);
    f->sample_rate = FB_RATE;
    av_frame_get_buffer(f, 0);
    const uint8_t* in[1] = {(const uint8_t*)(data + pos * channels)};
    swr_convert(swr, f->data, n, in, n);
    f->pts = pts;
    pts += n;
    encode_write(c, oc, st, f, pkt);
    av_frame_unref(f);
  }
  encode_write(c, oc, st, NULL, pkt);
  av_write_trailer(oc);
  av_frame_free(&f);
  av_packet_free(&pkt);
  swr_free(&swr);
  ret = 0;
done:
  avcodec_free_context(&c);
  if (oc && !(oc->oformat->flags & AVFMT_NOFILE)) avio_closep(&oc->pb);
  avformat_free_context(oc);
  return ret;
}

// ------------------------------------------------------------- loudness
// K-weighting biquads for 48 kHz (ITU-R BS.1770-4).
static const double KB1[3] = {1.53512485958697, -2.69169618940638, 1.19839281085285};
static const double KA1[3] = {1.0, -1.69065929318241, 0.73248077421585};
static const double KB2[3] = {1.0, -2.0, 1.0};
static const double KA2[3] = {1.0, -1.99004745483398, 0.99007225036621};

void fb_lufs_init(fb_lufs_state* s, int channels) {
  memset(s, 0, sizeof(*s));
  s->channels = channels;
}

static void lufs_free(fb_lufs_state* s) {
  free(s->blocks);
  s->blocks = NULL;
}

// Feeds samples; accumulates 100 ms sub-block energies.
void fb_lufs_feed(fb_lufs_state* s, const float* data, int64_t frames) {
  const int sub = FB_RATE / 10;
  for (int64_t i = 0; i < frames; i++) {
    double e = 0;
    for (int c = 0; c < s->channels && c < 2; c++) {
      double x = data[i * s->channels + c];
      double* z = s->z[c];
      // stage 1
      double y1 = KB1[0] * x + z[0];
      z[0] = KB1[1] * x - KA1[1] * y1 + z[1];
      z[1] = KB1[2] * x - KA1[2] * y1;
      // stage 2
      double y2 = KB2[0] * y1 + z[2];
      z[2] = KB2[1] * y1 - KA2[1] * y2 + z[3];
      z[3] = KB2[2] * y1 - KA2[2] * y2;
      e += y2 * y2;
    }
    // Mono is counted as if it were played on both channels: BS.1770 sums
    // channel energies, and a mono file played on stereo outputs twice.
    if (s->channels == 1) e *= 2;
    s->acc += e;
    if (++s->acc_n == sub) {
      if (s->nblocks == s->capblocks) {
        s->capblocks = s->capblocks ? s->capblocks * 2 : 256;
        s->blocks = realloc(s->blocks, sizeof(double) * s->capblocks);
      }
      s->blocks[s->nblocks++] = s->acc / sub;
      s->acc = 0;
      s->acc_n = 0;
    }
  }
}

double fb_lufs_value(const fb_lufs_state* s) {
  // 400 ms gating blocks = 4 sub-blocks, 75 % overlap.
  int nb = s->nblocks - 3;
  if (nb <= 0) {
    // Too short: use whatever we have.
    double sum = 0;
    for (int i = 0; i < s->nblocks; i++) sum += s->blocks[i];
    if (s->nblocks == 0 || sum <= 0) return -HUGE_VAL;
    return -0.691 + 10 * log10(sum / s->nblocks);
  }
  double* z = malloc(sizeof(double) * nb);
  for (int i = 0; i < nb; i++)
    z[i] = (s->blocks[i] + s->blocks[i + 1] + s->blocks[i + 2] + s->blocks[i + 3]) / 4;
  double abs_gate = pow(10, (-70 + 0.691) / 10);
  double sum = 0;
  int n = 0;
  for (int i = 0; i < nb; i++)
    if (z[i] > abs_gate) {
      sum += z[i];
      n++;
    }
  if (n == 0) {
    free(z);
    return -HUGE_VAL;
  }
  double rel_gate = (sum / n) * pow(10, -10.0 / 10);
  double sum2 = 0;
  int n2 = 0;
  for (int i = 0; i < nb; i++)
    if (z[i] > abs_gate && z[i] > rel_gate) {
      sum2 += z[i];
      n2++;
    }
  free(z);
  if (n2 == 0) return -HUGE_VAL;
  return -0.691 + 10 * log10(sum2 / n2);
}

void fb_lufs_destroy(fb_lufs_state* s) { lufs_free(s); }

double fb_loudness(const float* data, int64_t frames, int32_t channels) {
  fb_lufs_state s;
  fb_lufs_init(&s, channels);
  fb_lufs_feed(&s, data, frames);
  double v = fb_lufs_value(&s);
  fb_lufs_destroy(&s);
  return v;
}

typedef struct {
  fb_lufs_state lufs;
  double peak;
  int ch;
} analyze_ctx;

static void analyze_sink(void* user, const float* data, int64_t frames) {
  analyze_ctx* a = user;
  fb_lufs_feed(&a->lufs, data, frames);
  for (int64_t i = 0; i < frames * a->ch; i++) {
    double v = fabs(data[i]);
    if (v > a->peak) a->peak = v;
  }
}

int fb_analyze(const char* path, double* lufs, double* peak) {
  fb_decoder* d = fb_decoder_open(path);
  if (!d) return -1;
  analyze_ctx a;
  a.peak = 0;
  a.ch = d->channels;
  fb_lufs_init(&a.lufs, d->channels);
  while (fb_decoder_read(d, analyze_sink, &a) > 0) {
  }
  fb_decoder_close(d);
  *lufs = fb_lufs_value(&a.lufs);
  *peak = a.peak;
  fb_lufs_destroy(&a.lufs);
  return 0;
}
