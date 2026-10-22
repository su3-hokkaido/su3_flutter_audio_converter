// Public C interface of the audio conversion core (docs/project_plan.md section 5.2).
//
// Conversions run on a native worker thread. Progress and completion are reported through a
// callback that Dart receives with NativeCallable.listener, so the callback may be invoked from
// any thread and must not block.
//
// The bindings in lib/ are generated from this header with ffigen (regenerate-bindings skill).

#ifndef SU3_FLUTTER_AUDIO_CONVERTER_H_
#define SU3_FLUTTER_AUDIO_CONVERTER_H_

#include <stddef.h>
#include <stdint.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

// Audio formats (input detection and output). The values match the order of the Dart AudioFormat enum.
typedef enum su3_format {
  SU3_FORMAT_MP3 = 0,
  SU3_FORMAT_M4A = 1,
  SU3_FORMAT_WMA = 2,
  SU3_FORMAT_WAV = 3,
  SU3_FORMAT_AAC = 4,
} su3_format;

// Job states reported to the callback.
typedef enum su3_status {
  SU3_STATUS_RUNNING = 0,    // progress update
  SU3_STATUS_DONE = 1,       // finished; the output file is complete
  SU3_STATUS_FAILED = 2,     // failed; see error_code and su3_last_error
  SU3_STATUS_CANCELLED = 3,  // cancelled; the partial output file was removed
} su3_status;

// Error codes. The Dart side maps them to typed exceptions.
typedef enum su3_error {
  SU3_OK = 0,
  SU3_ERR_INVALID_ARGUMENT = 1,
  SU3_ERR_OPEN_INPUT = 2,          // input missing or unreadable
  SU3_ERR_UNSUPPORTED_FORMAT = 3,  // no audio stream, unknown or unimplemented format
  SU3_ERR_CORRUPTED = 4,           // input data could not be decoded
  SU3_ERR_UNSUPPORTED_BITRATE = 5,
  SU3_ERR_IO = 6,  // output could not be created or written
  SU3_ERR_CANCELLED = 7,
  SU3_ERR_OUT_OF_MEMORY = 8,
  SU3_ERR_INTERNAL = 9,
} su3_error;

typedef struct su3_convert_options {
  int32_t output_format;  // su3_format
  // MP3, M4A and AAC: 128, 192, 256 or 320. WMA: 128, 192 or 256 (320 fails with
  // SU3_ERR_UNSUPPORTED_BITRATE). Ignored for WAV. Validated when the job starts running, so an
  // invalid value ends the job with SU3_STATUS_FAILED.
  int32_t bitrate_kbps;
} su3_convert_options;

// Result of su3_probe. Unknown numeric values are -1 (sample_rate and channels are 0 when unknown).
typedef struct su3_audio_info {
  int32_t format;       // su3_format of the container, detected from the content; -1 if unknown
  int64_t duration_ms;  // -1 if unknown
  int32_t sample_rate;  // Hz
  int32_t channels;
  int64_t bitrate_bps;  // bits per second of the audio stream; -1 if unknown
} su3_audio_info;

// progress is 0.0 to 1.0 (or negative when the input duration is unknown). error_code is
// meaningful only for SU3_STATUS_FAILED. After a terminal status (DONE, FAILED, CANCELLED) no more
// callbacks are made for the job.
typedef void (*su3_job_callback)(int64_t job_id, double progress, int32_t status,
                                 int32_t error_code);

// Reads information about the best audio stream of the input. Synchronous and quick (it reads the
// header only), but it touches the file system, so call it off the UI isolate. The format is
// detected from the file content, not from its extension. Returns SU3_OK, SU3_ERR_OPEN_INPUT,
// SU3_ERR_UNSUPPORTED_FORMAT (unknown container, no or unsupported audio stream) or
// SU3_ERR_CORRUPTED. On failure *out holds the "unknown" values. Paths are UTF-8.
FFI_PLUGIN_EXPORT int32_t su3_probe(const char* input_path, su3_audio_info* out);

// Starts a conversion on a worker thread and returns a job id (> 0), or a negative su3_error value
// when the arguments are invalid (including identical input and output paths). Paths are UTF-8 and
// are copied. The output file is created only when the conversion starts and is removed on failure
// and cancellation.
//
// The sample rate and channel count of the input are kept. When the encoder does not support the
// input's sample rate, the nearest supported rate is used; lossy outputs (MP3, M4A, AAC, WMA) are
// at most stereo. WAV keeps the PCM bit depth of a PCM input and is 16-bit otherwise.
FFI_PLUGIN_EXPORT int64_t su3_convert_start(const char* input_path, const char* output_path,
                                            const su3_convert_options* options,
                                            su3_job_callback callback);

// Requests cancellation. Safe to call at any time, including for finished or unknown jobs.
FFI_PLUGIN_EXPORT void su3_convert_cancel(int64_t job_id);

// Copies the last error message of the job into buffer (NUL-terminated, truncated to buffer_size).
// Returns the job's error code, or SU3_ERR_INVALID_ARGUMENT for an unknown job.
FFI_PLUGIN_EXPORT int32_t su3_last_error(int64_t job_id, char* buffer, size_t buffer_size);

// Waits for the worker thread of a finished job and frees the job. Call it once after the terminal
// callback has been received. Releasing a running job waits for it to end.
FFI_PLUGIN_EXPORT void su3_job_release(int64_t job_id);

#endif  // SU3_FLUTTER_AUDIO_CONVERTER_H_
