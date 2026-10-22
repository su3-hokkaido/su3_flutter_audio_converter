// Native tests for the conversion core: the full 5 x 5 format matrix, su3_probe, bitrate validation
// and the job lifecycle. They link against the prebuilt FFmpeg libraries and need no Flutter; run
// them with tool/run_native_tests_macos.sh.
//
// Test inputs are generated here: WAV from a synthetic sine wave, MP3 and WMA by the package itself,
// M4A and AAC with the macOS `afconvert` tool when it exists (an independent encoder), otherwise by
// the package.
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
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

// Writes a PCM (or 32-bit float) sine wave. The data is self-made, so there is nothing to license.
// bits is 8, 16, 24 or 32; is_float selects IEEE float (32 bits only).
static void write_wav_ex(const char* path, int sample_rate, int channels, double seconds, int bits,
                         int is_float) {
  uint32_t frames = (uint32_t)(sample_rate * seconds);
  int bytes = bits / 8;
  uint32_t data_bytes = frames * channels * bytes;
  FILE* f = fopen(path, "wb");
  if (f == NULL) {
    fprintf(stderr, "cannot create %s\n", path);
    exit(2);
  }
  fwrite("RIFF", 1, 4, f);
  put32(f, 36 + data_bytes);
  fwrite("WAVEfmt ", 1, 8, f);
  put32(f, 16);
  put16(f, is_float ? 3 : 1);
  put16(f, (uint16_t)channels);
  put32(f, (uint32_t)sample_rate);
  put32(f, (uint32_t)(sample_rate * channels * bytes));
  put16(f, (uint16_t)(channels * bytes));
  put16(f, (uint16_t)bits);
  fwrite("data", 1, 4, f);
  put32(f, data_bytes);
  for (uint32_t i = 0; i < frames; i++) {
    double v = 0.4 * sin(2.0 * M_PI * 440.0 * i / sample_rate);
    for (int c = 0; c < channels; c++) {
      if (is_float) {
        float x = (float)v;
        fwrite(&x, 4, 1, f);
      } else if (bits == 8) {
        uint8_t x = (uint8_t)(128 + (int)(v * 127));
        fwrite(&x, 1, 1, f);
      } else if (bits == 16) {
        int16_t x = (int16_t)(v * 32767);
        fwrite(&x, 2, 1, f);
      } else if (bits == 24) {
        int32_t x = (int32_t)(v * 8388607);
        fwrite(&x, 3, 1, f);  // little endian: the low three bytes
      } else {
        int32_t x = (int32_t)(v * 2147483647.0);
        fwrite(&x, 4, 1, f);
      }
    }
  }
  fclose(f);
}

static void write_wav(const char* path, int sample_rate, int channels, double seconds) {
  write_wav_ex(path, sample_rate, channels, seconds, 16, 0);
}

static int file_exists(const char* path) { return access(path, F_OK) == 0; }

static int64_t start(const char* in, const char* out, int format, int bitrate) {
  su3_convert_options options = {format, bitrate};
  reset_result();
  return su3_convert_start(in, out, &options, on_job);
}

static const char* const kExt[] = {"mp3", "m4a", "wma", "wav", "aac"};  // indexed by su3_format
static const char* const kName[] = {"mp3", "m4a", "wma", "wav", "aac"};

typedef struct stream_info {
  int opened;
  enum AVCodecID codec_id;
  int sample_rate;
  int channels;
  double duration;
  int64_t bit_rate;
} stream_info;

// Reads the output with libavformat directly, independent of su3_probe.
static stream_info inspect(const char* path) {
  stream_info info = {0};
  AVFormatContext* ctx = NULL;
  if (avformat_open_input(&ctx, path, NULL, NULL) != 0) return info;
  if (avformat_find_stream_info(ctx, NULL) >= 0 && ctx->nb_streams > 0) {
    AVCodecParameters* par = ctx->streams[0]->codecpar;
    info.opened = 1;
    info.codec_id = par->codec_id;
    info.sample_rate = par->sample_rate;
    info.channels = par->ch_layout.nb_channels;
    info.duration = ctx->duration > 0 ? (double)ctx->duration / AV_TIME_BASE : -1.0;
    info.bit_rate = par->bit_rate > 0 ? par->bit_rate : ctx->bit_rate;
  }
  avformat_close_input(&ctx);
  return info;
}

static enum AVCodecID expected_codec(int format) {
  switch (format) {
    case SU3_FORMAT_MP3: return AV_CODEC_ID_MP3;
    case SU3_FORMAT_WMA: return AV_CODEC_ID_WMAV2;
    case SU3_FORMAT_WAV: return AV_CODEC_ID_PCM_S16LE;
    default: return AV_CODEC_ID_AAC;
  }
}

// Converts and waits. Returns the final status; the job is released.
static int run_job(const char* in, const char* out, int format, int bitrate, int* error_code) {
  int64_t job = start(in, out, format, bitrate);
  CHECK(job > 0);
  if (job <= 0) return -1;
  CHECK(wait_terminal());
  int status = g_result.status;
  if (error_code != NULL) *error_code = g_result.error_code;
  CHECK(g_result.terminal_count == 1);
  su3_job_release(job);
  return status;
}

static int has_afconvert(void) { return access("/usr/bin/afconvert", X_OK) == 0; }

// Creates a test input of `format` from a 2 s 44.1 kHz stereo WAV. M4A and AAC come from afconvert
// when available; the others come from the package. Returns 0 on success.
static int make_input(const char* dir, int format, char* path, size_t size) {
  char wav[512];
  snprintf(wav, sizeof wav, "%s/src_44100_2.wav", dir);
  snprintf(path, size, "%s/input_%s.%s", dir, kName[format], kExt[format]);
  write_wav(wav, 44100, 2, 2.0);
  if (format == SU3_FORMAT_WAV) {
    snprintf(path, size, "%s", wav);
    return 0;
  }
  if (has_afconvert() && (format == SU3_FORMAT_M4A || format == SU3_FORMAT_AAC)) {
    char cmd[1500];
    snprintf(cmd, sizeof cmd, "/usr/bin/afconvert -f %s -d aac -b 128000 '%s' '%s'",
             format == SU3_FORMAT_M4A ? "m4af" : "adts", wav, path);
    return system(cmd) == 0 ? 0 : 1;
  }
  return run_job(wav, path, format, 128, NULL) == SU3_STATUS_DONE ? 0 : 1;
}

static void test_matrix(const char* dir) {
  char inputs[5][512];
  for (int f = 0; f < 5; f++) {
    CHECK(make_input(dir, f, inputs[f], sizeof inputs[f]) == 0);
    su3_audio_info info;
    CHECK(su3_probe(inputs[f], &info) == SU3_OK);
    CHECK(info.format == f);
  }
  printf("matrix (inputs: m4a/aac via %s)\n", has_afconvert() ? "afconvert" : "the package");
  for (int from = 0; from < 5; from++) {
    for (int to = 0; to < 5; to++) {
      char out[512];
      snprintf(out, sizeof out, "%s/m_%s_to_%s.%s", dir, kName[from], kName[to], kExt[to]);
      int before = g_failures;
      int status = run_job(inputs[from], out, to, 128, NULL);
      CHECK(status == SU3_STATUS_DONE);
      stream_info info = inspect(out);
      CHECK(info.opened);
      CHECK(info.codec_id == expected_codec(to));
      CHECK(info.sample_rate == 44100);
      CHECK(info.channels == 2);
      CHECK(fabs(info.duration - 2.0) < 0.2);
      if (to != SU3_FORMAT_WAV) {
        CHECK(info.bit_rate > 128000 * 0.6 && info.bit_rate < 128000 * 1.4);
      }
      su3_audio_info probed;
      CHECK(su3_probe(out, &probed) == SU3_OK);
      CHECK(probed.format == to);
      printf("  %s -> %s: %s (%d Hz, %d ch, %.2f s, %lld bps)\n", kName[from], kName[to],
             g_failures == before ? "ok" : "FAILED", info.sample_rate, info.channels, info.duration,
             (long long)info.bit_rate);
    }
  }
}

// Different sample rates and channel counts from WAV into every output.
static void test_rates_and_channels(const char* dir) {
  static const struct {
    int rate, channels;
  } cases[] = {{8000, 1}, {22050, 1}, {32000, 2}, {48000, 2}, {96000, 2}, {44100, 6}, {11025, 2}};
  printf("sample rates and channel counts\n");
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
    char in[512];
    snprintf(in, sizeof in, "%s/rc_%d_%d.wav", dir, cases[i].rate, cases[i].channels);
    write_wav(in, cases[i].rate, cases[i].channels, 2.0);
    for (int to = 0; to < 5; to++) {
      char out[512];
      snprintf(out, sizeof out, "%s/rc_out_%d_%d.%s", dir, cases[i].rate, cases[i].channels, kExt[to]);
      int error = 0;
      int status = run_job(in, out, to, 128, &error);
      stream_info info = inspect(out);
      if (status != SU3_STATUS_DONE) {
        printf("  %5d Hz %d ch -> %s: failed with error %d\n", cases[i].rate, cases[i].channels,
               kName[to], error);
        CHECK(0);
        continue;
      }
      int expect_channels = (to == SU3_FORMAT_WAV || cases[i].channels <= 2) ? cases[i].channels : 2;
      CHECK(info.opened);
      CHECK(info.channels == expect_channels);
      CHECK(fabs(info.duration - 2.0) < 0.2);
      if (to == SU3_FORMAT_WAV) CHECK(info.sample_rate == cases[i].rate);
      printf("  %5d Hz %d ch -> %s: %d Hz, %d ch\n", cases[i].rate, cases[i].channels, kName[to],
             info.sample_rate, info.channels);
    }
  }
}

// WAV output keeps the PCM sample type of a PCM input and is 16-bit for everything else.
static void test_wav_bit_depth(const char* dir) {
  static const struct {
    int bits, is_float;
    enum AVCodecID expected;
  } cases[] = {{8, 0, AV_CODEC_ID_PCM_S16LE},
               {16, 0, AV_CODEC_ID_PCM_S16LE},
               {24, 0, AV_CODEC_ID_PCM_S24LE},
               {32, 0, AV_CODEC_ID_PCM_S32LE},
               {32, 1, AV_CODEC_ID_PCM_F32LE}};
  printf("wav bit depth\n");
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
    char in[512], out[512];
    snprintf(in, sizeof in, "%s/depth_%d_%d.wav", dir, cases[i].bits, cases[i].is_float);
    snprintf(out, sizeof out, "%s/depth_%d_%d_out.wav", dir, cases[i].bits, cases[i].is_float);
    write_wav_ex(in, 44100, 2, 1.0, cases[i].bits, cases[i].is_float);
    CHECK(run_job(in, out, SU3_FORMAT_WAV, 0, NULL) == SU3_STATUS_DONE);
    stream_info info = inspect(out);
    CHECK(info.opened);
    CHECK(info.codec_id == cases[i].expected);
    CHECK(info.sample_rate == 44100 && info.channels == 2);
    CHECK(fabs(info.duration - 1.0) < 0.05);
  }
}

static void test_bitrates(const char* dir) {
  char in[512], out[512];
  snprintf(in, sizeof in, "%s/src_44100_2.wav", dir);
  write_wav(in, 44100, 2, 2.0);
  printf("bitrates\n");
  for (int to = 0; to < 5; to++) {
    if (to == SU3_FORMAT_WAV) continue;
    static const int rates[] = {128, 192, 256, 320};
    for (int i = 0; i < 4; i++) {
      snprintf(out, sizeof out, "%s/br_%d.%s", dir, rates[i], kExt[to]);
      int error = 0;
      int status = run_job(in, out, to, rates[i], &error);
      if (to == SU3_FORMAT_WMA && rates[i] == 320) {
        CHECK(status == SU3_STATUS_FAILED);
        CHECK(error == SU3_ERR_UNSUPPORTED_BITRATE);
        CHECK(!file_exists(out));
        continue;
      }
      CHECK(status == SU3_STATUS_DONE);
      stream_info info = inspect(out);
      CHECK(info.opened);
      CHECK(info.bit_rate > rates[i] * 1000LL * 0.6 && info.bit_rate < rates[i] * 1000LL * 1.4);
      printf("  %s %d kbps: %lld bps\n", kName[to], rates[i], (long long)info.bit_rate);
    }
    snprintf(out, sizeof out, "%s/br_bad.%s", dir, kExt[to]);
    int error = 0;
    CHECK(run_job(in, out, to, 100, &error) == SU3_STATUS_FAILED);
    CHECK(error == SU3_ERR_UNSUPPORTED_BITRATE);
    CHECK(!file_exists(out));
  }
  // The bitrate is ignored for WAV.
  snprintf(out, sizeof out, "%s/br_ignored.wav", dir);
  CHECK(run_job(in, out, SU3_FORMAT_WAV, 12345, NULL) == SU3_STATUS_DONE);
  CHECK(run_job(in, out, SU3_FORMAT_WAV, 0, NULL) == SU3_STATUS_DONE);
}

static void test_probe(const char* dir) {
  printf("probe\n");
  su3_audio_info info;
  char path[512];
  CHECK(su3_probe(NULL, &info) == SU3_ERR_INVALID_ARGUMENT);
  CHECK(su3_probe("x", NULL) == SU3_ERR_INVALID_ARGUMENT);
  CHECK(su3_probe("/nonexistent/input.wav", &info) == SU3_ERR_OPEN_INPUT);
  CHECK(info.format == -1 && info.duration_ms == -1 && info.bitrate_bps == -1);

  snprintf(path, sizeof path, "%s/probe_garbage.bin", dir);
  FILE* f = fopen(path, "wb");
  for (int i = 0; i < 4096; i++) fputc((i * 31) & 0xff, f);
  fclose(f);
  CHECK(su3_probe(path, &info) != SU3_OK);

  // Values for a known WAV.
  snprintf(path, sizeof path, "%s/probe_22050_1.wav", dir);
  write_wav(path, 22050, 1, 3.0);
  CHECK(su3_probe(path, &info) == SU3_OK);
  CHECK(info.format == SU3_FORMAT_WAV);
  CHECK(llabs(info.duration_ms - 3000) <= 5);
  CHECK(info.sample_rate == 22050 && info.channels == 1);
  CHECK(info.bitrate_bps == 22050 * 16);

  // Detection uses the content, not the extension: WAV data named .mp3 and MP3 data named .wav.
  char disguised[512], converted[512], mp3[512], mp3_as_wav[512];
  snprintf(disguised, sizeof disguised, "%s/disguised.mp3", dir);
  snprintf(mp3, sizeof mp3, "%s/probe_real.mp3", dir);
  snprintf(mp3_as_wav, sizeof mp3_as_wav, "%s/disguised.wav", dir);
  snprintf(converted, sizeof converted, "%s/disguised_out.m4a", dir);
  write_wav(disguised, 44100, 2, 1.0);
  CHECK(su3_probe(disguised, &info) == SU3_OK);
  CHECK(info.format == SU3_FORMAT_WAV);
  CHECK(run_job(disguised, mp3, SU3_FORMAT_MP3, 128, NULL) == SU3_STATUS_DONE);
  char cmd[1200];
  snprintf(cmd, sizeof cmd, "cp '%s' '%s'", mp3, mp3_as_wav);
  CHECK(system(cmd) == 0);
  CHECK(su3_probe(mp3_as_wav, &info) == SU3_OK);
  CHECK(info.format == SU3_FORMAT_MP3);
  CHECK(info.sample_rate == 44100 && info.channels == 2);
  CHECK(info.bitrate_bps > 100000 && info.bitrate_bps < 160000);
  CHECK(run_job(mp3_as_wav, converted, SU3_FORMAT_M4A, 128, NULL) == SU3_STATUS_DONE);
  printf("  detected a %s file named .wav\n", kName[info.format]);
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
  snprintf(in, sizeof in, "%s/src_44100_2.wav", dir);
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

static void test_unknown_output_format(const char* dir) {
  char in[512], out[512];
  snprintf(in, sizeof in, "%s/src_44100_2.wav", dir);
  snprintf(out, sizeof out, "%s/unknown.bin", dir);
  printf("unknown output format\n");
  int error = 0;
  CHECK(run_job(in, out, 99, 128, &error) == SU3_STATUS_FAILED);
  CHECK(error == SU3_ERR_UNSUPPORTED_FORMAT);
  CHECK(!file_exists(out));
}

static void test_cancel(const char* dir) {
  char in[512];
  snprintf(in, sizeof in, "%s/long.wav", dir);
  write_wav(in, 44100, 2, 120.0);
  for (int to = 0; to < 5; to++) {
    char out[512];
    snprintf(out, sizeof out, "%s/cancelled.%s", dir, kExt[to]);
    printf("cancel (%s)\n", kName[to]);
    int64_t job = start(in, out, to, 256);
    CHECK(job > 0);
    usleep(to * 20000);  // cancel at different points: header written, mid-stream
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
}

static void test_invalid_arguments(void) {
  printf("invalid arguments\n");
  su3_convert_options options = {SU3_FORMAT_MP3, 128};
  CHECK(su3_convert_start(NULL, "a", &options, on_job) < 0);
  CHECK(su3_convert_start("a", NULL, &options, on_job) < 0);
  CHECK(su3_convert_start("a", "b", NULL, on_job) < 0);
  CHECK(su3_convert_start("a", "b", &options, NULL) < 0);
  CHECK(su3_convert_start("same.wav", "same.wav", &options, on_job) < 0);
  su3_convert_cancel(123456);  // unknown job: must not crash
  su3_job_release(123456);
  char message[16];
  CHECK(su3_last_error(123456, message, sizeof message) == SU3_ERR_INVALID_ARGUMENT);
}

static void test_same_file(const char* dir) {
  char in[512], alias[512], link[512];
  printf("same file\n");
  snprintf(in, sizeof in, "%s/same_src.wav", dir);
  write_wav(in, 8000, 1, 0.2);
  su3_convert_options options = {SU3_FORMAT_WAV, 128};
  snprintf(alias, sizeof alias, "%s/./same_src.wav", dir);
  CHECK(su3_convert_start(in, alias, &options, on_job) < 0);
  snprintf(link, sizeof link, "%s/same_link.wav", dir);
  unlink(link);
  CHECK(symlink(in, link) == 0);
  CHECK(su3_convert_start(in, link, &options, on_job) < 0);
  snprintf(alias, sizeof alias, "%s/sub/../same_src.wav", dir);
  char sub[512];
  snprintf(sub, sizeof sub, "%s/sub", dir);
  mkdir(sub, 0755);
  CHECK(su3_convert_start(in, alias, &options, on_job) < 0);
  unlink(link);
  rmdir(sub);
  CHECK(file_exists(in));
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <scratch dir>\n", argv[0]);
    return 2;
  }
  pthread_mutex_init(&g_result.mutex, NULL);
  av_log_set_level(AV_LOG_ERROR);  // keep the encoder's informational warnings out of the output
  const char* dir = argv[1];

  test_matrix(dir);
  test_rates_and_channels(dir);
  test_wav_bit_depth(dir);
  test_bitrates(dir);
  test_probe(dir);
  test_missing_input(dir);
  test_corrupted_input(dir);
  test_unsupported_bitrate(dir);
  test_unknown_output_format(dir);
  test_cancel(dir);
  test_invalid_arguments();
  test_same_file(dir);

  if (g_failures == 0) {
    printf("All native tests passed.\n");
    return 0;
  }
  printf("%d check(s) failed.\n", g_failures);
  return 1;
}
