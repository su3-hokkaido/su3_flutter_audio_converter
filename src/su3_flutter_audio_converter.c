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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if _WIN32
#include <windows.h>
typedef HANDLE su3_thread;
typedef CRITICAL_SECTION su3_mutex;
#else
#include <pthread.h>
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

static void set_error(su3_job* job, int code, const char* what, int averror) {
  job->error_code = code;
  if (averror < 0) {
    char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(averror, detail, sizeof(detail));
    snprintf(job->error_message, sizeof(job->error_message), "%s: %s", what, detail);
  } else {
    snprintf(job->error_message, sizeof(job->error_message), "%s", what);
  }
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

static int pick_supported_sample_rate(AVCodecContext* encoder, const AVCodec* codec, int wanted) {
  const int* rates = NULL;
  int count = 0;
  if (avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_RATE, 0,
                                   (const void**)&rates, &count) < 0 ||
      rates == NULL) {
    return wanted;  // any rate is accepted
  }
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
  if (ret >= 0 && av_audio_fifo_read(c->fifo, (void**)frame->data, samples) < samples) {
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
  int frame_size = c->encoder->frame_size > 0 ? c->encoder->frame_size : 1152;
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

static int open_input(converter* c) {
  su3_job* job = c->job;
  int ret = avformat_open_input(&c->input, job->input_path, NULL, NULL);
  if (ret < 0) {
    set_error(job, ret == AVERROR_INVALIDDATA ? SU3_ERR_UNSUPPORTED_FORMAT : SU3_ERR_OPEN_INPUT,
              "Cannot open the input file", ret);
    return job->error_code;
  }
  ret = avformat_find_stream_info(c->input, NULL);
  if (ret < 0) {
    set_error(job, SU3_ERR_CORRUPTED, "Cannot read the input stream information", ret);
    return job->error_code;
  }
  const AVCodec* decoder = NULL;
  c->input_stream_index = av_find_best_stream(c->input, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
  if (c->input_stream_index < 0 || decoder == NULL) {
    set_error(job, SU3_ERR_UNSUPPORTED_FORMAT, "No supported audio stream in the input", 0);
    return job->error_code;
  }
  c->decoder = avcodec_alloc_context3(decoder);
  if (c->decoder == NULL) {
    set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", 0);
    return job->error_code;
  }
  avcodec_parameters_to_context(c->decoder, c->input->streams[c->input_stream_index]->codecpar);
  ret = avcodec_open2(c->decoder, decoder, NULL);
  if (ret < 0) {
    set_error(job, SU3_ERR_UNSUPPORTED_FORMAT, "Cannot open the decoder", ret);
    return job->error_code;
  }
  if (c->decoder->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
    av_channel_layout_default(&c->decoder->ch_layout, c->decoder->ch_layout.nb_channels);
  }
  return SU3_OK;
}

static int open_mp3_output(converter* c) {
  su3_job* job = c->job;
  int bitrate = job->options.bitrate_kbps;
  if (bitrate != 128 && bitrate != 192 && bitrate != 256 && bitrate != 320) {
    set_error(job, SU3_ERR_UNSUPPORTED_BITRATE, "Unsupported bitrate", 0);
    return job->error_code;
  }
  int ret = avformat_alloc_output_context2(&c->output, NULL, "mp3", job->output_path);
  const AVCodec* codec = avcodec_find_encoder_by_name("libmp3lame");
  if (ret < 0 || codec == NULL) {
    set_error(job, SU3_ERR_UNSUPPORTED_FORMAT, "The MP3 encoder is not available", ret);
    return job->error_code;
  }
  c->encoder = avcodec_alloc_context3(codec);
  if (c->encoder == NULL) {
    set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", 0);
    return job->error_code;
  }
  // MP3 supports mono and stereo; anything else is mixed down to stereo.
  av_channel_layout_default(&c->encoder->ch_layout,
                            c->decoder->ch_layout.nb_channels == 1 ? 1 : 2);
  c->encoder->sample_rate = pick_supported_sample_rate(c->encoder, codec, c->decoder->sample_rate);
  c->encoder->sample_fmt = pick_sample_format(c->encoder, codec);
  if (c->encoder->sample_fmt == AV_SAMPLE_FMT_NONE) {
    set_error(job, SU3_ERR_INTERNAL, "The MP3 encoder reports no sample format", 0);
    return job->error_code;
  }
  c->encoder->bit_rate = (int64_t)bitrate * 1000;
  c->encoder->time_base = (AVRational){1, c->encoder->sample_rate};
  if (c->output->oformat->flags & AVFMT_GLOBALHEADER) {
    c->encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  ret = avcodec_open2(c->encoder, codec, NULL);
  if (ret < 0) {
    // The encoder rejects bitrates its sample rate cannot carry (for example 320 kbps at 22 kHz).
    set_error(job, SU3_ERR_UNSUPPORTED_BITRATE, "The encoder rejected the bitrate", ret);
    return job->error_code;
  }
  AVStream* stream = avformat_new_stream(c->output, NULL);
  if (stream == NULL) {
    set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", 0);
    return job->error_code;
  }
  avcodec_parameters_from_context(stream->codecpar, c->encoder);
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
      if (c->packet->pts != AV_NOPTS_VALUE && duration > 0.0) {
        report_progress(c, c->packet->pts * av_q2d(stream->time_base) / duration);
      }
      ret = decode_packet(c, c->packet);
      if (ret < 0) {
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
  if (ret >= 0) ret = resample_to_fifo(c, NULL);
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
  if (job->options.output_format != SU3_FORMAT_MP3) {
    set_error(job, SU3_ERR_UNSUPPORTED_FORMAT, "This output format is not implemented yet", 0);
    return job->error_code;
  }

  c.packet = av_packet_alloc();
  c.frame = av_frame_alloc();
  if (c.packet == NULL || c.frame == NULL) {
    set_error(job, SU3_ERR_OUT_OF_MEMORY, "Out of memory", 0);
    code = job->error_code;
  }
  if (code == SU3_OK) code = open_input(&c);
  if (code == SU3_OK) code = open_mp3_output(&c);
  if (code == SU3_OK) code = transcode(&c);

  if (c.output != NULL && c.output->pb != NULL) avio_closep(&c.output->pb);
  if (code != SU3_OK && c.output_opened) remove(job->output_path);

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
  job->error_code = code;
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

FFI_PLUGIN_EXPORT int64_t su3_convert_start(const char* input_path, const char* output_path,
                                            const su3_convert_options* options,
                                            su3_job_callback callback) {
  if (input_path == NULL || output_path == NULL || options == NULL || callback == NULL) {
    return -SU3_ERR_INVALID_ARGUMENT;
  }
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
