// Generates the WAV, MP3 and WMA test fixtures in test/fixtures/ (see tool/make_fixtures_macos.sh).
//
// The WAV is a synthetic 1 s mono 22.05 kHz 16-bit clip (a sine sweep with a slow amplitude
// modulation), written here, so no third-party audio is involved. The MP3 and WMA files are made
// from it with the package's own native core (su3_convert_start), which keeps the fixtures
// reproducible without an ffmpeg command line tool.
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "../src/su3_flutter_audio_converter.h"

#define RATE 22050
#define SECONDS 1

static volatile int g_status = 0;
static volatile int g_error = 0;

static void on_event(int64_t job, double progress, int32_t status, int32_t error) {
  (void)job;
  (void)progress;
  if (status != SU3_STATUS_RUNNING) {
    g_error = error;
    g_status = status;
  }
}

static void put32(FILE* f, uint32_t v) {
  for (int i = 0; i < 4; i++) fputc((int)((v >> (8 * i)) & 0xFF), f);
}
static void put16(FILE* f, uint16_t v) {
  fputc(v & 0xFF, f);
  fputc(v >> 8, f);
}

static int write_wav(const char* path) {
  FILE* f = fopen(path, "wb");
  if (!f) return 1;
  const uint32_t frames = RATE * SECONDS;
  const uint32_t bytes = frames * 2;
  fwrite("RIFF", 1, 4, f);
  put32(f, 36 + bytes);
  fwrite("WAVEfmt ", 1, 8, f);
  put32(f, 16);
  put16(f, 1);
  put16(f, 1);
  put32(f, RATE);
  put32(f, RATE * 2);
  put16(f, 2);
  put16(f, 16);
  fwrite("data", 1, 4, f);
  put32(f, bytes);
  double phase = 0;
  for (uint32_t i = 0; i < frames; i++) {
    double t = (double)i / RATE;
    double freq = 300.0 + 900.0 * t;  // 300 Hz to 1200 Hz sweep
    phase += 2.0 * M_PI * freq / RATE;
    double amp = 9000.0 * (0.6 + 0.4 * sin(2.0 * M_PI * 3.0 * t));
    put16(f, (uint16_t)(int16_t)lrint(amp * sin(phase)));
  }
  return fclose(f);
}

static int convert(const char* in, const char* out, int format, int kbps) {
  su3_convert_options options = {format, kbps};
  g_status = 0;
  int64_t job = su3_convert_start(in, out, &options, on_event);
  if (job <= 0) return 1;
  while (g_status == 0) usleep(2000);
  int ok = g_status == SU3_STATUS_DONE;
  su3_job_release(job);
  return ok ? 0 : 1;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <output dir>\n", argv[0]);
    return 2;
  }
  char wav[1024], mp3[1024], wma[1024];
  snprintf(wav, sizeof wav, "%s/tone.wav", argv[1]);
  snprintf(mp3, sizeof mp3, "%s/tone.mp3", argv[1]);
  snprintf(wma, sizeof wma, "%s/tone.wma", argv[1]);
  if (write_wav(wav) != 0) return 1;
  if (convert(wav, mp3, SU3_FORMAT_MP3, 128) != 0) return 1;
  if (convert(wav, wma, SU3_FORMAT_WMA, 128) != 0) return 1;
  return 0;
}
