// Native tests for the conversion core (wav -> mp3 and the job lifecycle). They link against the
// prebuilt FFmpeg libraries and need no Flutter; run them with tool/run_native_tests_macos.sh.
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../../src/su3_flutter_audio_converter.h"

static int g_failures = 0;
#define CHECK(condition)                                                    \
  do {                                                                      \
    if (!(condition)) {                                                     \
      fprintf(stderr, "  FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
      g_failures++;                                                         \
    }                                                                       \
  } while (0)

typedef struct result {
  pthread_mutex_t mutex;
  int terminal;
  int status;
  int error_code;
  int updates;
  int terminal_count;
  double last_progress;
} result;

static result g_result;

static void on_job(int64_t job_id, double progress, int32_t status, int32_t error_code) {
  (void)job_id;
  pthread_mutex_lock(&g_result.mutex);
  if (status == SU3_STATUS_RUNNING) {
    g_result.updates++;
    g_result.last_progress = progress;
  } else {
    g_result.terminal = 1;
    g_result.terminal_count++;
    g_result.status = status;
    g_result.error_code = error_code;
  }
  pthread_mutex_unlock(&g_result.mutex);
}

static void reset_result(void) {
  pthread_mutex_lock(&g_result.mutex);
  g_result.terminal = 0;
  g_result.status = -1;
  g_result.error_code = -1;
  g_result.updates = 0;
  g_result.terminal_count = 0;
  g_result.last_progress = -1.0;
  pthread_mutex_unlock(&g_result.mutex);
}

static int wait_terminal(void) {
  for (int i = 0; i < 6000; i++) {  // up to 60 s
    pthread_mutex_lock(&g_result.mutex);
    int done = g_result.terminal;
    pthread_mutex_unlock(&g_result.mutex);
    if (done) return 1;
    usleep(10000);
  }
  return 0;
}

static void put16(FILE* f, uint16_t v) { fwrite(&v, 2, 1, f); }
static void put32(FILE* f, uint32_t v) { fwrite(&v, 4, 1, f); }

// Writes a 16-bit PCM sine wave. The data is self-made, so there is nothing to license.
static void write_wav(const char* path, int sample_rate, int channels, double seconds) {
  uint32_t frames = (uint32_t)(sample_rate * seconds);
  uint32_t data_bytes = frames * channels * 2;
  FILE* f = fopen(path, "wb");
  fwrite("RIFF", 1, 4, f);
  put32(f, 36 + data_bytes);
  fwrite("WAVEfmt ", 1, 8, f);
  put32(f, 16);
  put16(f, 1);
  put16(f, (uint16_t)channels);
  put32(f, (uint32_t)sample_rate);
  put32(f, (uint32_t)(sample_rate * channels * 2));
  put16(f, (uint16_t)(channels * 2));
  put16(f, 16);
  fwrite("data", 1, 4, f);
  put32(f, data_bytes);
  for (uint32_t i = 0; i < frames; i++) {
    int16_t s = (int16_t)(12000.0 * sin(2.0 * M_PI * 440.0 * i / sample_rate));
    for (int c = 0; c < channels; c++) fwrite(&s, 2, 1, f);
  }
  fclose(f);
}

static int file_exists(const char* path) { return access(path, F_OK) == 0; }

static int64_t start(const char* in, const char* out, int format, int bitrate) {
  su3_convert_options options = {format, bitrate};
  reset_result();
  return su3_convert_start(in, out, &options, on_job);
}

static void test_wav_to_mp3(const char* dir, int rate, int channels, int bitrate) {
  char in[512], out[512];
  snprintf(in, sizeof in, "%s/in_%d_%d.wav", dir, rate, channels);
  snprintf(out, sizeof out, "%s/out_%d_%d_%d.mp3", dir, rate, channels, bitrate);
  printf("wav -> mp3 (%d Hz, %d ch, %d kbps)\n", rate, channels, bitrate);
  write_wav(in, rate, channels, 2.0);

  int64_t job = start(in, out, SU3_FORMAT_MP3, bitrate);
  CHECK(job > 0);
  CHECK(wait_terminal());
  CHECK(g_result.status == SU3_STATUS_DONE);
  CHECK(g_result.terminal_count == 1);
  CHECK(g_result.last_progress <= 1.0);

  AVFormatContext* ctx = NULL;
  CHECK(avformat_open_input(&ctx, out, NULL, NULL) == 0);
  if (ctx != NULL) {
    CHECK(avformat_find_stream_info(ctx, NULL) >= 0);
    AVCodecParameters* par = ctx->streams[0]->codecpar;
    CHECK(par->codec_id == AV_CODEC_ID_MP3);
    CHECK(par->sample_rate == rate);
    CHECK(par->ch_layout.nb_channels == channels);
    double duration = (double)ctx->duration / AV_TIME_BASE;
    CHECK(fabs(duration - 2.0) < 0.15);
    CHECK(llabs(par->bit_rate - bitrate * 1000LL) < bitrate * 1000LL / 20);
    avformat_close_input(&ctx);
  }
  su3_job_release(job);
}

static void test_missing_input(const char* dir) {
  char out[512];
  snprintf(out, sizeof out, "%s/never.mp3", dir);
  printf("missing input\n");
  int64_t job = start("/nonexistent/input.wav", out, SU3_FORMAT_MP3, 128);
  CHECK(job > 0);
  CHECK(wait_terminal());
  CHECK(g_result.status == SU3_STATUS_FAILED);
  CHECK(g_result.error_code == SU3_ERR_OPEN_INPUT);
  char message[512];
  CHECK(su3_last_error(job, message, sizeof message) == SU3_ERR_OPEN_INPUT);
  CHECK(strlen(message) > 0);
  CHECK(!file_exists(out));
  su3_job_release(job);
}

static void test_corrupted_input(const char* dir) {
  char in[512], out[512];
  snprintf(in, sizeof in, "%s/garbage.wav", dir);
  snprintf(out, sizeof out, "%s/garbage.mp3", dir);
  printf("garbage input\n");
  FILE* f = fopen(in, "wb");
  for (int i = 0; i < 4096; i++) fputc((i * 31) & 0xff, f);
  fclose(f);
  int64_t job = start(in, out, SU3_FORMAT_MP3, 128);
  CHECK(job > 0);
  CHECK(wait_terminal());
  CHECK(g_result.status == SU3_STATUS_FAILED);
  CHECK(!file_exists(out));
  su3_job_release(job);
}

static void test_unsupported_bitrate(const char* dir) {
  char in[512], out[512];
  snprintf(in, sizeof in, "%s/in_44100_2.wav", dir);
  snprintf(out, sizeof out, "%s/bad_bitrate.mp3", dir);
  printf("unsupported bitrate\n");
  int64_t job = start(in, out, SU3_FORMAT_MP3, 100);
  CHECK(job > 0);
  CHECK(wait_terminal());
  CHECK(g_result.status == SU3_STATUS_FAILED);
  CHECK(g_result.error_code == SU3_ERR_UNSUPPORTED_BITRATE);
  CHECK(!file_exists(out));
  su3_job_release(job);
}

static void test_unimplemented_format(const char* dir) {
  char in[512], out[512];
  snprintf(in, sizeof in, "%s/in_44100_2.wav", dir);
  snprintf(out, sizeof out, "%s/not_yet.m4a", dir);
  printf("output format not implemented yet\n");
  int64_t job = start(in, out, SU3_FORMAT_M4A, 128);
  CHECK(job > 0);
  CHECK(wait_terminal());
  CHECK(g_result.status == SU3_STATUS_FAILED);
  CHECK(g_result.error_code == SU3_ERR_UNSUPPORTED_FORMAT);
  CHECK(!file_exists(out));
  su3_job_release(job);
}

static void test_cancel(const char* dir) {
  char in[512], out[512];
  snprintf(in, sizeof in, "%s/long.wav", dir);
  snprintf(out, sizeof out, "%s/cancelled.mp3", dir);
  printf("cancel\n");
  write_wav(in, 44100, 2, 120.0);
  int64_t job = start(in, out, SU3_FORMAT_MP3, 320);
  CHECK(job > 0);
  su3_convert_cancel(job);
  CHECK(wait_terminal());
  // The cancel request can lose the race against a very fast conversion; both outcomes must be
  // consistent: a cancelled job leaves no output, and exactly one terminal callback is made.
  CHECK(g_result.status == SU3_STATUS_CANCELLED || g_result.status == SU3_STATUS_DONE);
  if (g_result.status == SU3_STATUS_CANCELLED) {
    CHECK(!file_exists(out));
  }
  usleep(100000);
  CHECK(g_result.terminal_count == 1);
  su3_job_release(job);
}

static void test_invalid_arguments(void) {
  printf("invalid arguments\n");
  su3_convert_options options = {SU3_FORMAT_MP3, 128};
  CHECK(su3_convert_start(NULL, "a", &options, on_job) < 0);
  CHECK(su3_convert_start("a", NULL, &options, on_job) < 0);
  CHECK(su3_convert_start("a", "b", NULL, on_job) < 0);
  CHECK(su3_convert_start("a", "b", &options, NULL) < 0);
  su3_convert_cancel(123456);  // unknown job: must not crash
  su3_job_release(123456);
  char message[16];
  CHECK(su3_last_error(123456, message, sizeof message) == SU3_ERR_INVALID_ARGUMENT);
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <scratch dir>\n", argv[0]);
    return 2;
  }
  pthread_mutex_init(&g_result.mutex, NULL);
  const char* dir = argv[1];

  test_wav_to_mp3(dir, 44100, 2, 128);
  test_wav_to_mp3(dir, 44100, 2, 320);
  test_wav_to_mp3(dir, 44100, 1, 192);
  test_wav_to_mp3(dir, 48000, 2, 256);
  test_missing_input(dir);
  test_corrupted_input(dir);
  test_unsupported_bitrate(dir);
  test_unimplemented_format(dir);
  test_cancel(dir);
  test_invalid_arguments();

  if (g_failures == 0) {
    printf("All native tests passed.\n");
    return 0;
  }
  printf("%d check(s) failed.\n", g_failures);
  return 1;
}
