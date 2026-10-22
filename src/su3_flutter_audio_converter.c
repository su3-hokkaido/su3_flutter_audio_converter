#include "su3_flutter_audio_converter.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <errno.h>
#include <libswresample/swresample.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if _WIN32
#include <stdio.h>
#include <wchar.h>
#include <windows.h>
typedef HANDLE su3_thread;
typedef CRITICAL_SECTION su3_mutex;
#else
#include <pthread.h>
#include <unistd.h>
typedef pthread_t su3_thread;
typedef pthread_mutex_t su3_mutex;
#endif

// ---------------------------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------------------------

typedef struct su3_job {
  int64_t id;
  char* input_path;
  char* output_path;
  su3_convert_options options;
  su3_job_callback callback;
  int cancel_requested;  // guarded by the global lock
  int error_code;        // written by the worker before the terminal callback
  char error_message[512];
  su3_thread thread;
  struct su3_job* next;
} su3_job;

static su3_job* g_jobs = NULL;  // guarded by the global lock
static int64_t g_next_job_id = 1;

#if _WIN32
static INIT_ONCE g_lock_once = INIT_ONCE_STATIC_INIT;
static su3_mutex g_lock;
static BOOL CALLBACK init_lock(PINIT_ONCE once, PVOID param, PVOID* context) {
  (void)once;
  (void)param;
  (void)context;
  InitializeCriticalSection(&g_lock);
  return TRUE;
}
static void lock(void) {
  InitOnceExecuteOnce(&g_lock_once, init_lock, NULL, NULL);
  EnterCriticalSection(&g_lock);
}
static void unlock(void) { LeaveCriticalSection(&g_lock); }
#else
static su3_mutex g_lock = PTHREAD_MUTEX_INITIALIZER;
static void lock(void) { pthread_mutex_lock(&g_lock); }
static void unlock(void) { pthread_mutex_unlock(&g_lock); }
#endif

static su3_job* find_job_locked(int64_t id) {
  for (su3_job* job = g_jobs; job != NULL; job = job->next) {
    if (job->id == id) return job;
  }
  return NULL;
}

static int is_cancel_requested(su3_job* job) {
  lock();
  int requested = job->cancel_requested;
  unlock();
  return requested;
}

// Records the error under the global lock, because su3_last_error may read it at any time.
static void set_error(su3_job* job, int code, const char* what, int averror) {
  char message[sizeof(job->error_message)];
  if (averror < 0) {
    char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(averror, detail, sizeof(detail));
    snprintf(message, sizeof(message), "%s: %s", what, detail);
  } else {
    snprintf(message, sizeof(message), "%s", what);
  }
  lock();
  job->error_code = code;
  memcpy(job->error_message, message, sizeof(message));
  unlock();
}

// Removes a partial output file. Paths are UTF-8; on Windows they are converted to UTF-16 because
// the narrow C runtime functions use the ANSI code page.
static void remove_file_utf8(const char* path) {
#if _WIN32
  int count = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
  if (count <= 0) return;
  wchar_t* wide = (wchar_t*)malloc((size_t)count * sizeof(wchar_t));
  if (wide == NULL) return;
  if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, count) > 0) _wremove(wide);
  free(wide);
#else
  remove(path);
#endif
}

// ---------------------------------------------------------------------------------------------
// Conversion
// ---------------------------------------------------------------------------------------------

typedef struct converter {
  su3_job* job;
  AVFormatContext* input;
  AVFormatContext* output;
  AVCodecContext* decoder;
  AVCodecContext* encoder;
  SwrContext* resampler;
  AVAudioFifo* fifo;
  AVPacket* packet;
  AVFrame* frame;
  int input_stream_index;
  int output_opened;  // the output file was created and must be removed on failure
  int64_t next_pts;
  double last_reported;
} converter;

static void report_progress(converter* c, double progress) {
  // Report at most every 1% to keep the callback traffic small.
  if (progress < 0.0 || progress - c->last_reported < 0.01) return;
  c->last_reported = progress;
  c->job->callback(c->job->id, progress > 1.0 ? 1.0 : progress, SU3_STATUS_RUNNING, SU3_OK);
}

// Picks the sample rate the encoder supports that is nearest to `wanted`. Encoders that report no
// list use `fallback` (may be NULL: any rate is accepted).
static int pick_supported_sample_rate(AVCodecContext* encoder, const AVCodec* codec, int wanted,
                                      const int* fallback, int fallback_count) {
  const int* rates = NULL;
  int count = 0;
  if (avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_RATE, 0,
                                   (const void**)&rates, &count) < 0 ||
      rates == NULL || count < 1) {
    rates = fallback;
    count = fallback_count;
  }
  if (rates == NULL || count < 1) return wanted;
  int best = rates[0];
  for (int i = 0; i < count; i++) {
    if (rates[i] == wanted) return wanted;
    if (abs(rates[i] - wanted) < abs(best - wanted)) best = rates[i];
  }
  return best;
}

static enum AVSampleFormat pick_sample_format(AVCodecContext* encoder, const AVCodec* codec) {
  const enum AVSampleFormat* formats = NULL;
  int count = 0;
  if (avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0,
                                   (const void**)&formats, &count) < 0 ||
      formats == NULL || count < 1) {
    return AV_SAMPLE_FMT_NONE;
  }
  return formats[0];
}

// Sends the frame (or NULL to flush) to the encoder and writes every packet it returns.
static int encode_and_write(converter* c, AVFrame* frame) {
  int ret = avcodec_send_frame(c->encoder, frame);
  if (ret < 0) return ret;
  AVPacket* packet = av_packet_alloc();
  if (packet == NULL) return AVERROR(ENOMEM);
  while ((ret = avcodec_receive_packet(c->encoder, packet)) >= 0) {
    packet->stream_index = 0;
    av_packet_rescale_ts(packet, c->encoder->time_base, c->output->streams[0]->time_base);
    ret = av_interleaved_write_frame(c->output, packet);
    av_packet_unref(packet);
    if (ret < 0) break;
  }
  av_packet_free(&packet);
  return (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) ? 0 : ret;
}

// Reads up to `samples` from the FIFO into one frame and encodes it.
static int encode_from_fifo(converter* c, int samples) {
  AVFrame* frame = av_frame_alloc();
  if (frame == NULL) return AVERROR(ENOMEM);
  frame->nb_samples = samples;
  frame->format = c->encoder->sample_fmt;
  frame->sample_rate = c->encoder->sample_rate;
  int ret = av_channel_layout_copy(&frame->ch_layout, &c->encoder->ch_layout);
  if (ret >= 0) ret = av_frame_get_buffer(frame, 0);
  if (ret >= 0 && av_audio_fifo_read(c->fifo, (void**)frame->extended_data, samples) < samples) {
    ret = AVERROR_UNKNOWN;
  }
  if (ret >= 0) {
    frame->pts = c->next_pts;
    c->next_pts += samples;
    ret = encode_and_write(c, frame);
  }
  av_frame_free(&frame);
  return ret;
}

static int drain_fifo(converter* c, int flush) {
  // PCM encoders accept any frame size.
  int frame_size = c->encoder->frame_size > 0 ? c->encoder->frame_size : 4096;
  while (av_audio_fifo_size(c->fifo) >= frame_size) {
    int ret = encode_from_fifo(c, frame_size);
    if (ret < 0) return ret;
  }
  if (flush && av_audio_fifo_size(c->fifo) > 0) {
    // The last frame may be shorter than frame_size.
    return encode_from_fifo(c, av_audio_fifo_size(c->fifo));
  }
  return 0;
}

// Resamples `input` (NULL to flush the resampler) into the FIFO.
static int resample_to_fifo(converter* c, const AVFrame* input) {
  int in_samples = input != NULL ? input->nb_samples : 0;
  int max_out = swr_get_out_samples(c->resampler, in_samples);
  if (max_out <= 0) return 0;
  uint8_t** converted = NULL;
  int linesize = 0;
  int ret = av_samples_alloc_array_and_samples(&converted, &linesize,
                                               c->encoder->ch_layout.nb_channels, max_out,
                                               c->encoder->sample_fmt, 0);
  if (ret < 0) return ret;
  int produced = swr_convert(c->resampler, converted, max_out,
                             input != NULL ? (const uint8_t* const*)input->extended_data : NULL,
                             in_samples);
  if (produced < 0) {
    ret = produced;
  } else if (produced > 0) {
    ret = av_audio_fifo_write(c->fifo, (void**)converted, produced);
    if (ret >= 0 && ret < produced) ret = AVERROR_UNKNOWN;
    if (ret >= 0) ret = 0;
  } else {
    ret = 0;
  }
  av_freep(&converted[0]);
  av_freep(&converted);
  return ret;
}

static int decode_packet(converter* c, AVPacket* packet) {
  int ret = avcodec_send_packet(c->decoder, packet);
  if (ret < 0) return ret;
  while ((ret = avcodec_receive_frame(c->decoder, c->frame)) >= 0) {
    ret = resample_to_fifo(c, c->frame);
    av_frame_unref(c->frame);
    if (ret < 0) return ret;
    ret = drain_fifo(c, 0);
    if (ret < 0) return ret;
  }
  return (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) ? 0 : ret;
}

// Maps a demuxer name to the su3_format, or -1 when the container is not one of the five.
static int format_from_demuxer(const AVInputFormat* format) {
  if (format == NULL || format->name == NULL) return -1;
  const char* name = format->name;
  if (strcmp(name, "mp3") == 0) return SU3_FORMAT_MP3;
  if (strstr(name, "mp4") != NULL || strstr(name, "m4a") != NULL) return SU3_FORMAT_M4A;
  if (strcmp(name, "asf") == 0) return SU3_FORMAT_WMA;
  if (strcmp(name, "wav") == 0) return SU3_FORMAT_WAV;
  if (strcmp(name, "aac") == 0) return SU3_FORMAT_AAC;
  return -1;
}

// Opens the input by probing its content (the file extension is not used) and selects the best
// audio stream. On failure fills `error` / `message` and returns the su3_error code.
static int open_input_context(const char* path, AVFormatContext** input, int* stream_index,
                              const AVCodec** decoder, char* message, size_t message_size) {
  int ret = avformat_open_input(input, path, NULL, NULL);
  if (ret < 0) {
    char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(ret, detail, sizeof(detail));
    snprintf(message, message_size, "Cannot open the input file: %s", detail);
    return ret == AVERROR_INVALIDDATA ? SU3_ERR_UNSUPPORTED_FORMAT : SU3_ERR_OPEN_INPUT;
  }
  ret = avformat_find_stream_info(*input, NULL);
  if (ret < 0) {
    char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(ret, detail, sizeof(detail));
    snprintf(message, message_size, "Cannot read the input stream information: %s", detail);
    return SU3_ERR_CORRUPTED;
  }
  *decoder = NULL;
  *stream_index = av_find_best_stream(*input, AVMEDIA_TYPE_AUDIO, -1, -1, decoder, 0);
  if (*stream_index < 0 || *decoder == NULL) {
    snprintf(message, message_size, "No supported audio stream in the input");
    return SU3_ERR_UNSUPPORTED_FORMAT;
  }
  return SU3_OK;
}

static int open_input(converter* c) {
  su3_job* job = c->job;
  const AVCodec* decoder = NULL;
  char message[sizeof(job->error_message)];
  int code = open_input_context(job->input_path, &c->input, &c->input_stream_index, &decoder,
                                message, sizeof(message));
  if (code != SU3_OK) {
    set_error(job, code, message, 0);
    return code;
  }
  c->decoder = avcodec_alloc_context3(decoder);
  if (c->decoder == NULL) {
    set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", 0);
    return job->error_code;
  }
  int ret = avcodec_parameters_to_context(c->decoder,
                                          c->input->streams[c->input_stream_index]->codecpar);
  if (ret >= 0) ret = avcodec_open2(c->decoder, decoder, NULL);
  if (ret < 0) {
    set_error(job, SU3_ERR_UNSUPPORTED_FORMAT, "Cannot open the decoder", ret);
    return job->error_code;
  }
  if (c->decoder->sample_rate <= 0 || c->decoder->ch_layout.nb_channels <= 0) {
    set_error(job, SU3_ERR_CORRUPTED, "The input has no valid sample rate or channel count", 0);
    return job->error_code;
  }
  if (c->decoder->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
    av_channel_layout_default(&c->decoder->ch_layout, c->decoder->ch_layout.nb_channels);
  }
  return SU3_OK;
}

// Output description: muxer, encoder and the bitrates the format accepts.
typedef struct output_spec {
  const char* muxer;
  const char* encoder;  // NULL for WAV: chosen from the input
  int has_bitrate;
  int max_bitrate_kbps;  // 320 or 256
} output_spec;

static int get_output_spec(int format, output_spec* spec) {
  switch (format) {
    case SU3_FORMAT_MP3: *spec = (output_spec){"mp3", "libmp3lame", 1, 320}; return 1;
    case SU3_FORMAT_M4A: *spec = (output_spec){"ipod", "aac", 1, 320}; return 1;
    case SU3_FORMAT_AAC: *spec = (output_spec){"adts", "aac", 1, 320}; return 1;
    case SU3_FORMAT_WMA: *spec = (output_spec){"asf", "wmav2", 1, 256}; return 1;  // decision #16
    case SU3_FORMAT_WAV: *spec = (output_spec){"wav", NULL, 0, 0}; return 1;
    default: return 0;
  }
}

// WAV keeps the PCM sample type of a PCM input; compressed input (and 8-bit PCM, for which no
// encoder is enabled) becomes 16-bit (docs/project_plan.md section 3.3).
static const char* pcm_encoder_for(enum AVCodecID decoder_id) {
  switch (decoder_id) {
    case AV_CODEC_ID_PCM_S24LE: return "pcm_s24le";
    case AV_CODEC_ID_PCM_S32LE: return "pcm_s32le";
    case AV_CODEC_ID_PCM_F32LE: return "pcm_f32le";
    default: return "pcm_s16le";
  }
}

// Sample rates WMA v2 can carry. The encoder reports no list, so this table is the fallback.
static const int kWmaSampleRates[] = {8000, 11025, 16000, 22050, 32000, 44100, 48000};

static int open_output(converter* c, const output_spec* spec) {
  su3_job* job = c->job;
  int bitrate = job->options.bitrate_kbps;
  int ret = avformat_alloc_output_context2(&c->output, NULL, spec->muxer, job->output_path);
  const char* encoder_name =
      spec->encoder != NULL ? spec->encoder : pcm_encoder_for(c->decoder->codec_id);
  const AVCodec* codec = avcodec_find_encoder_by_name(encoder_name);
  if (ret < 0 || c->output == NULL || codec == NULL) {
    set_error(job, SU3_ERR_UNSUPPORTED_FORMAT, "The output format is not available", ret);
    return job->error_code;
  }
  c->encoder = avcodec_alloc_context3(codec);
  if (c->encoder == NULL) {
    set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", 0);
    return job->error_code;
  }
  if (spec->has_bitrate) {
    // Lossy encoders are used with mono or stereo; more channels are mixed down to stereo.
    av_channel_layout_default(&c->encoder->ch_layout,
                              c->decoder->ch_layout.nb_channels == 1 ? 1 : 2);
  } else {
    ret = av_channel_layout_copy(&c->encoder->ch_layout, &c->decoder->ch_layout);
    if (ret < 0) {
      set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", ret);
      return job->error_code;
    }
  }
  int is_wma = strcmp(spec->muxer, "asf") == 0;
  c->encoder->sample_rate = pick_supported_sample_rate(
      c->encoder, codec, c->decoder->sample_rate, is_wma ? kWmaSampleRates : NULL,
      is_wma ? (int)(sizeof(kWmaSampleRates) / sizeof(kWmaSampleRates[0])) : 0);
  c->encoder->sample_fmt = pick_sample_format(c->encoder, codec);
  if (c->encoder->sample_fmt == AV_SAMPLE_FMT_NONE) {
    set_error(job, SU3_ERR_INTERNAL, "The encoder reports no sample format", 0);
    return job->error_code;
  }
  if (spec->has_bitrate) c->encoder->bit_rate = (int64_t)bitrate * 1000;
  c->encoder->time_base = (AVRational){1, c->encoder->sample_rate};
  if (c->output->oformat->flags & AVFMT_GLOBALHEADER) {
    c->encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  ret = avcodec_open2(c->encoder, codec, NULL);
  if (ret < 0) {
    // The encoder rejects bitrates its sample rate cannot carry with EINVAL; other failures are
    // not a bitrate problem.
    int code = ret == AVERROR(ENOMEM) ? SU3_ERR_OUT_OF_MEMORY
               : (ret == AVERROR(EINVAL) && spec->has_bitrate) ? SU3_ERR_UNSUPPORTED_BITRATE
                                                               : SU3_ERR_INTERNAL;
    set_error(job, code, "The encoder rejected the parameters", ret);
    return job->error_code;
  }
  AVStream* stream = avformat_new_stream(c->output, NULL);
  if (stream == NULL) {
    set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", 0);
    return job->error_code;
  }
  ret = avcodec_parameters_from_context(stream->codecpar, c->encoder);
  if (ret < 0) {
    set_error(job, SU3_ERR_INTERNAL, "Cannot describe the output stream", ret);
    return job->error_code;
  }
  stream->time_base = c->encoder->time_base;

  ret = avio_open(&c->output->pb, job->output_path, AVIO_FLAG_WRITE);
  if (ret < 0) {
    set_error(job, SU3_ERR_IO, "Cannot create the output file", ret);
    return job->error_code;
  }
  c->output_opened = 1;
  ret = avformat_write_header(c->output, NULL);
  if (ret < 0) {
    set_error(job, SU3_ERR_IO, "Cannot write the output header", ret);
    return job->error_code;
  }

  ret = swr_alloc_set_opts2(&c->resampler, &c->encoder->ch_layout, c->encoder->sample_fmt,
                            c->encoder->sample_rate, &c->decoder->ch_layout,
                            c->decoder->sample_fmt, c->decoder->sample_rate, 0, NULL);
  if (ret >= 0) ret = swr_init(c->resampler);
  if (ret < 0) {
    set_error(job, SU3_ERR_INTERNAL, "Cannot set up the resampler", ret);
    return job->error_code;
  }
  c->fifo = av_audio_fifo_alloc(c->encoder->sample_fmt, c->encoder->ch_layout.nb_channels, 1);
  if (c->fifo == NULL) {
    set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", 0);
    return job->error_code;
  }
  return SU3_OK;
}

static int transcode(converter* c) {
  su3_job* job = c->job;
  AVStream* stream = c->input->streams[c->input_stream_index];
  double duration = c->input->duration > 0 ? (double)c->input->duration / AV_TIME_BASE : 0.0;
  int ret;

  while ((ret = av_read_frame(c->input, c->packet)) >= 0) {
    if (is_cancel_requested(job)) {
      av_packet_unref(c->packet);
      set_error(job, SU3_ERR_CANCELLED, "Cancelled", 0);
      return SU3_ERR_CANCELLED;
    }
    if (c->packet->stream_index == c->input_stream_index) {
      int64_t stamp = c->packet->pts != AV_NOPTS_VALUE ? c->packet->pts : c->packet->dts;
      if (stamp != AV_NOPTS_VALUE && duration > 0.0) {
        report_progress(c, stamp * av_q2d(stream->time_base) / duration);
      }
      ret = decode_packet(c, c->packet);
      if (ret < 0) {
        // By design a corrupted packet fails the whole conversion (no skipping of bad data).
        av_packet_unref(c->packet);
        set_error(job, ret == AVERROR_INVALIDDATA ? SU3_ERR_CORRUPTED : SU3_ERR_INTERNAL,
                  "Decoding failed", ret);
        return job->error_code;
      }
    }
    av_packet_unref(c->packet);
  }
  if (ret != AVERROR_EOF) {
    set_error(job, SU3_ERR_CORRUPTED, "Reading the input failed", ret);
    return job->error_code;
  }

  // Flush the decoder, then the resampler, then the encoder.
  ret = decode_packet(c, NULL);
  // Flush the resampler until it returns no more samples, so no tail is left behind.
  while (ret >= 0) {
    int before = av_audio_fifo_size(c->fifo);
    ret = resample_to_fifo(c, NULL);
    if (ret >= 0 && av_audio_fifo_size(c->fifo) == before) break;
  }
  if (ret >= 0) ret = drain_fifo(c, 1);
  if (ret >= 0) ret = encode_and_write(c, NULL);
  if (ret >= 0) ret = av_write_trailer(c->output);
  if (ret < 0) {
    set_error(job, SU3_ERR_IO, "Finishing the output failed", ret);
    return job->error_code;
  }
  return SU3_OK;
}

static int run_conversion(su3_job* job) {
  converter c;
  memset(&c, 0, sizeof(c));
  c.job = job;
  c.last_reported = -1.0;

  int code = SU3_OK;
  output_spec spec;
  if (!get_output_spec(job->options.output_format, &spec)) {
    set_error(job, SU3_ERR_UNSUPPORTED_FORMAT, "Unknown output format", 0);
    return job->error_code;
  }
  if (spec.has_bitrate) {
    int kbps = job->options.bitrate_kbps;
    if ((kbps != 128 && kbps != 192 && kbps != 256 && kbps != 320) || kbps > spec.max_bitrate_kbps) {
      set_error(job, SU3_ERR_UNSUPPORTED_BITRATE, "Unsupported bitrate for this format", 0);
      return job->error_code;
    }
  }

  c.packet = av_packet_alloc();
  c.frame = av_frame_alloc();
  if (c.packet == NULL || c.frame == NULL) {
    set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", 0);
    code = job->error_code;
  }
  if (code == SU3_OK) code = open_input(&c);
  if (code == SU3_OK) code = open_output(&c, &spec);
  if (code == SU3_OK) code = transcode(&c);

  if (c.output != NULL && c.output->pb != NULL) avio_closep(&c.output->pb);
  if (code != SU3_OK && c.output_opened) remove_file_utf8(job->output_path);

  av_audio_fifo_free(c.fifo);
  swr_free(&c.resampler);
  avcodec_free_context(&c.encoder);
  avcodec_free_context(&c.decoder);
  avformat_free_context(c.output);
  avformat_close_input(&c.input);
  av_frame_free(&c.frame);
  av_packet_free(&c.packet);
  return code;
}

static void worker_main(su3_job* job) {
  int code = run_conversion(job);
  int status = code == SU3_OK              ? SU3_STATUS_DONE
               : code == SU3_ERR_CANCELLED ? SU3_STATUS_CANCELLED
                                           : SU3_STATUS_FAILED;
  lock();
  job->error_code = code;
  if (code == SU3_OK) job->error_message[0] = '\0';
  unlock();
  job->callback(job->id, status == SU3_STATUS_DONE ? 1.0 : 0.0, status, code);
}

#if _WIN32
static DWORD WINAPI worker_entry(LPVOID arg) {
  worker_main((su3_job*)arg);
  return 0;
}
#else
static void* worker_entry(void* arg) {
  worker_main((su3_job*)arg);
  return NULL;
}
#endif

// ---------------------------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------------------------

static char* copy_string(const char* text) {
  size_t size = strlen(text) + 1;
  char* copy = (char*)malloc(size);
  if (copy != NULL) memcpy(copy, text, size);
  return copy;
}

static void free_job(su3_job* job) {
  free(job->input_path);
  free(job->output_path);
  free(job);
}

FFI_PLUGIN_EXPORT int32_t su3_probe(const char* input_path, su3_audio_info* out) {
  if (input_path == NULL || out == NULL) return SU3_ERR_INVALID_ARGUMENT;
  out->format = -1;
  out->duration_ms = -1;
  out->sample_rate = 0;
  out->channels = 0;
  out->bitrate_bps = -1;

  AVFormatContext* input = NULL;
  const AVCodec* decoder = NULL;
  int stream_index = -1;
  char message[256];
  int code = open_input_context(input_path, &input, &stream_index, &decoder, message,
                                sizeof(message));
  if (code == SU3_OK) {
    const AVCodecParameters* par = input->streams[stream_index]->codecpar;
    out->format = format_from_demuxer(input->iformat);
    if (input->duration != AV_NOPTS_VALUE && input->duration >= 0) {
      out->duration_ms = av_rescale(input->duration, 1000, AV_TIME_BASE);
    }
    out->sample_rate = par->sample_rate;
    out->channels = par->ch_layout.nb_channels;
    if (par->bit_rate > 0) {
      out->bitrate_bps = par->bit_rate;
    } else if (input->bit_rate > 0) {
      out->bitrate_bps = input->bit_rate;
    }
  }
  avformat_close_input(&input);
  return code;
}

// True when both paths name the same file. POSIX: compares real paths (symlinks and relative
// segments resolved); a not yet existing output is resolved through its parent directory. Windows
// keeps the plain string comparison (hard links, case and 8.3 names are not detected there).
static int is_same_file(const char* input_path, const char* output_path) {
  if (strcmp(input_path, output_path) == 0) return 1;
#if !_WIN32
  char in_real[PATH_MAX];
  char out_real[PATH_MAX];
  if (realpath(input_path, in_real) == NULL) return 0;  // missing input fails later anyway
  if (realpath(output_path, out_real) != NULL) return strcmp(in_real, out_real) == 0;
  // Output does not exist: resolve its directory and append the file name.
  const char* slash = strrchr(output_path, '/');
  char dir[PATH_MAX];
  const char* name = slash != NULL ? slash + 1 : output_path;
  if (slash == NULL) {
    snprintf(dir, sizeof(dir), ".");
  } else if (slash == output_path) {
    snprintf(dir, sizeof(dir), "/");
  } else {
    size_t length = (size_t)(slash - output_path);
    if (length >= sizeof(dir)) return 0;
    memcpy(dir, output_path, length);
    dir[length] = '\0';
  }
  char dir_real[PATH_MAX];
  if (realpath(dir, dir_real) == NULL) return 0;
  char joined[PATH_MAX * 2];
  snprintf(joined, sizeof(joined), "%s%s%s", dir_real,
           strcmp(dir_real, "/") == 0 ? "" : "/", name);
  return strcmp(in_real, joined) == 0;
#else
  return 0;
#endif
}

FFI_PLUGIN_EXPORT int64_t su3_convert_start(const char* input_path, const char* output_path,
                                            const su3_convert_options* options,
                                            su3_job_callback callback) {
  if (input_path == NULL || output_path == NULL || options == NULL || callback == NULL) {
    return -SU3_ERR_INVALID_ARGUMENT;
  }
  // Writing over the input would destroy it (and a failed job removes its output).
  if (is_same_file(input_path, output_path)) return -SU3_ERR_INVALID_ARGUMENT;
  su3_job* job = (su3_job*)calloc(1, sizeof(su3_job));
  if (job == NULL) return -SU3_ERR_OUT_OF_MEMORY;
  job->input_path = copy_string(input_path);
  job->output_path = copy_string(output_path);
  job->options = *options;
  job->callback = callback;
  if (job->input_path == NULL || job->output_path == NULL) {
    free_job(job);
    return -SU3_ERR_OUT_OF_MEMORY;
  }

  lock();
  job->id = g_next_job_id++;
  job->next = g_jobs;
  g_jobs = job;
  unlock();

#if _WIN32
  job->thread = CreateThread(NULL, 0, worker_entry, job, 0, NULL);
  int started = job->thread != NULL;
#else
  int started = pthread_create(&job->thread, NULL, worker_entry, job) == 0;
#endif
  if (!started) {
    lock();
    for (su3_job** link = &g_jobs; *link != NULL; link = &(*link)->next) {
      if (*link == job) {
        *link = job->next;
        break;
      }
    }
    unlock();
    free_job(job);
    return -SU3_ERR_INTERNAL;
  }
  return job->id;
}

FFI_PLUGIN_EXPORT void su3_convert_cancel(int64_t job_id) {
  lock();
  su3_job* job = find_job_locked(job_id);
  if (job != NULL) job->cancel_requested = 1;
  unlock();
}

FFI_PLUGIN_EXPORT int32_t su3_last_error(int64_t job_id, char* buffer, size_t buffer_size) {
  lock();
  su3_job* job = find_job_locked(job_id);
  int32_t code = SU3_ERR_INVALID_ARGUMENT;
  if (job != NULL) {
    code = job->error_code;
    if (buffer != NULL && buffer_size > 0) {
      snprintf(buffer, buffer_size, "%s", job->error_message);
    }
  } else if (buffer != NULL && buffer_size > 0) {
    buffer[0] = '\0';
  }
  unlock();
  return code;
}

FFI_PLUGIN_EXPORT void su3_job_release(int64_t job_id) {
  lock();
  su3_job* job = NULL;
  for (su3_job** link = &g_jobs; *link != NULL; link = &(*link)->next) {
    if ((*link)->id == job_id) {
      job = *link;
      *link = job->next;
      break;
    }
  }
  unlock();
  if (job == NULL) return;
#if _WIN32
  WaitForSingleObject(job->thread, INFINITE);
  CloseHandle(job->thread);
#else
  pthread_join(job->thread, NULL);
#endif
  free_job(job);
}
