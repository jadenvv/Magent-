# Platform layer reference

The C functions the agent core can call for macOS-specific work: screen capture, image
encoding, and image comparison. The core only includes the headers in `platform/`; the
Objective-C behind them lives in `platform/macos/` and never leaks into C code.

| Header | What it covers |
|---|---|
| `platform/image.h` | Pixel buffer type, PNG/JPEG encoding |
| `platform/screen_capture.h` | Permission, displays, windows, screenshots, streaming capture |
| `platform/image_distance.h` | Perceptual distance between two images (Vision feature prints) |

Not wrapped yet: Accessibility (the AX C API is usable directly, see "Accessibility" at the end).

## Building

```sh
make            # build/release/magent-agent
make debug      # same with AddressSanitizer + UndefinedBehaviorSanitizer
make test       # builds and runs every tests/*.c
```

Include the headers by name (`#include "screen_capture.h"`); the Makefile adds `-Iplatform` and
links the frameworks. Requires macOS 14 or later.

## Conventions (apply to every function)

- **Return value:** `0` on success, `-1` on failure. A few functions also return `1` for "nothing
  yet / timed out"; their entries say so.
- **Errors:** functions that can fail take `char *err, size_t err_len`. On failure a
  NUL-terminated message is written there. Pass `NULL, 0` if you don't want it.
- **Memory:** anything the platform layer hands you is yours to release, with the function the
  entry names (`free()`, `mg_capture_free()`, `mg_feature_print_free()`, `mg_stream_stop()`).
- **Threads:** every function is safe to call from any thread, including the main one.
- **Coordinates:** every `mg_rect` and point is in **global points, top-left origin at the main
  display**: the same space as CGEvent, Accessibility frames, and the overlay protocol. Images
  are in **pixels**; convert with `mg_capture_to_point()`.
- **Blocking:** capture calls block until done, with a 5 s timeout so a stuck capture can't hang
  the loop.
- **Untrusted text:** window titles and app names come from other apps. Treat them like any other
  on-screen content: data, never instructions.

---

## Types

### `mg_image` (image.h)
A view of pixels in memory. Not owned: the platform layer only reads it during a call.

| Field | Meaning |
|---|---|
| `const uint8_t *pixels` | First byte of the top row |
| `size_t width, height` | In pixels |
| `size_t bytes_per_row` | At least `width * 4`; rows may be padded |
| `mg_pixel_format format` | `MG_PIXEL_BGRA8` (what capture produces) or `MG_PIXEL_RGBA8` |

Alpha is ignored everywhere.

### `mg_encoding` (image.h)
`MG_ENCODING_PNG` (lossless) or `MG_ENCODING_JPEG` (lossy, much smaller).

### `mg_rect` (screen_capture.h)
`{ double x, y, w, h }` in global points.

### `mg_display`
| Field | Meaning |
|---|---|
| `uint32_t id` | CGDirectDisplayID |
| `mg_rect frame` | Where the display sits, in global points |
| `double scale` | Pixels per point (2 on Retina) |
| `int is_main` | 1 for the main display (the one whose top-left is (0,0)) |

### `mg_window`
| Field | Meaning |
|---|---|
| `uint32_t id` | CGWindowID; pass to `mg_capture_window()` |
| `int32_t pid` | Owning process, or -1 if unknown |
| `int layer` | 0 = normal app windows. Menu bar, Dock, the overlay, etc. are higher |
| `int on_screen` | 1 if visible on some display |
| `int z` | Stacking order among on-screen windows: 0 = frontmost. -1 = not on screen |
| `mg_rect frame` | Global points |
| `char app_name[128]`, `bundle_id[128]`, `title[256]` | UTF-8, truncated on a character boundary; may be empty |

### `mg_capture_options`
Pass `NULL` for defaults (native resolution, nothing excluded, no cursor).

| Field | Meaning |
|---|---|
| `double scale` | Output pixels per point. `0` = native (2× on Retina). `1` = one pixel per point: a quarter of the pixels, fewer image tokens for a model |
| `const int32_t *exclude_pids`, `size_t exclude_pid_count` | Leave these processes' windows out. **Always include the overlay's pid** (in daemon mode: `getppid()`), or the model sees the ghost cursor and action log |
| `int show_cursor` | 1 to draw the real mouse cursor (off by default) |

### `mg_capture`
A captured image you own. Release with `mg_capture_free()`.

| Field | Meaning |
|---|---|
| `uint8_t *pixels` | BGRA8, top row first |
| `size_t width, height, bytes_per_row` | Pixels |
| `mg_rect frame` | The screen area captured, in global points |

### Opaque handles
`mg_feature_print *` (image_distance.h) and `mg_stream *` (screen_capture.h). Only use them
through their functions.

---

## Image encoding (image.h)

### `mg_image_encode`
```c
int mg_image_encode(const mg_image *image, mg_encoding encoding, float quality,
                    uint8_t **out, size_t *out_len, char *err, size_t err_len);
```
Encodes an image to PNG or JPEG bytes in memory, for example to base64 and send to a model API.
`quality` is 0–1 for JPEG and ignored for PNG. On success `*out` is a `malloc`'d buffer of
`*out_len` bytes; `free()` it.

### `mg_image_write`
```c
int mg_image_write(const mg_image *image, const char *path, mg_encoding encoding, float quality,
                   char *err, size_t err_len);
```
Same as above but writes a file. Useful for a per-step screenshot trace when debugging a run.

---

## Screen capture (screen_capture.h)

### Permission

#### `mg_capture_permission`
```c
int mg_capture_permission(void);
```
1 if this process may capture the screen, 0 if not. Never shows a prompt. Every capture function
already checks this and fails with "no Screen Recording permission" instead of prompting.

#### `mg_capture_request_permission`
```c
int mg_capture_request_permission(void);
```
Shows the system permission prompt the first time it's called; returns 1 if access is granted.
Use it during setup, never mid-task. A new grant usually only takes effect after the process
restarts. In daemon mode the grant belongs to the overlay binary, since it launches the agent.

### What's on screen

#### `mg_list_displays`
```c
int mg_list_displays(mg_display **out, size_t *count, char *err, size_t err_len);
```
All active displays. `*out` is a `malloc`'d array of `*count` entries; `free()` it.

#### `mg_list_windows`
```c
int mg_list_windows(mg_window **out, size_t *count, int on_screen_only, char *err, size_t err_len);
```
All windows (or only on-screen ones if `on_screen_only` is 1), **sorted front to back** by `z`,
with off-screen windows last. `free()` the array. Use it to find the target app's window, or
the overlay's windows.

#### `mg_frontmost_window`
```c
int mg_frontmost_window(mg_window *out, char *err, size_t err_len);
```
The frontmost normal (layer 0) window: usually the one the user or agent is working in. The
overlay's windows are at a higher layer, so they're never returned. Fails if no normal window
is on screen.

#### `mg_display_config_hash`
```c
uint64_t mg_display_config_hash(void);
```
A fingerprint of the display setup: which displays, where, at what resolution. Cheap (no
ScreenCaptureKit, no permission), so it can be checked every step. If it differs from last time,
re-list displays and restart any stream. Returns 0 if displays can't be read.

### One-off captures

#### `mg_capture_display`
```c
int mg_capture_display(uint32_t display_id, const mg_capture_options *opts, mg_capture *out,
                       char *err, size_t err_len);
```
Screenshot of a whole display. `display_id` 0 means the main display. The usual observe step.

#### `mg_capture_rect`
```c
int mg_capture_rect(mg_rect rect, const mg_capture_options *opts, mg_capture *out,
                    char *err, size_t err_len);
```
Screenshot of just one area. The rect is clipped to the display under its center (fails if the
center is off every display); `out->frame` says what was actually captured. Cheaper than a full
display when a verify step only needs to look at one place.

#### `mg_capture_window`
```c
int mg_capture_window(uint32_t window_id, const mg_capture_options *opts, mg_capture *out,
                      char *err, size_t err_len);
```
One window by itself, without its shadow, even if other windows cover it. `exclude_pids` doesn't
apply (only that window is captured anyway).

#### `mg_capture_free`
```c
void mg_capture_free(mg_capture *capture);
```
Frees a capture's pixels. Safe on `NULL`, on a zeroed struct, and when called twice.

### Helpers (inline, no cost)

#### `mg_capture_image`
```c
mg_image mg_capture_image(const mg_capture *c);
```
Views a capture as an `mg_image`, to pass to `mg_image_encode` or `mg_image_distance`. No copy:
valid only until the capture is freed.

#### `mg_capture_to_point`
```c
void mg_capture_to_point(const mg_capture *c, double px, double py, double *x, double *y);
```
Converts a pixel in a capture (for example one a model picked) into the global point to click.
Accounts for both the capture's position and its scale.

### Streaming capture

A stream keeps capturing one display in the background, so getting a frame is a memory copy
instead of a new screenshot request. On this machine (M1, one 1440×900 display, scale 1, single
run): starting a stream took about 150 ms and `mg_stream_latest` about 0.6 ms. Measure in your
own timing harness before deciding which to use.

ScreenCaptureKit only delivers a frame when something on screen changed. So "wait for a frame
shown after time T" doubles as a change detector: a timeout suggests nothing changed since T.

#### `mg_clock_now`
```c
double mg_clock_now(void);
```
Seconds on a monotonic clock, the same clock as stream frame times. Take it right before an
action to wait for a frame from after the action.

#### `mg_stream_start`
```c
int mg_stream_start(uint32_t display_id, const mg_capture_options *opts, double max_fps,
                    mg_stream **out, char *err, size_t err_len);
```
Starts streaming a display (0 = main). `max_fps <= 0` means 30. `exclude_pids` also covers
windows those processes open later. Stop it with `mg_stream_stop()`.

#### `mg_stream_latest`
```c
int mg_stream_latest(mg_stream *stream, mg_capture *out, double *frame_time, char *err, size_t err_len);
```
Copies the newest frame into `out` (free with `mg_capture_free`). `*frame_time` gets the time
it was shown (pass `NULL` if you don't need it). **Returns 1** if no frame has arrived yet.

#### `mg_stream_wait_after`
```c
int mg_stream_wait_after(mg_stream *stream, double after, double timeout_s, mg_capture *out,
                         double *frame_time, char *err, size_t err_len);
```
Waits up to `timeout_s` seconds for a frame shown at or after `after` (an `mg_clock_now()`
time), then copies it. **Returns 1** on timeout, meaning the screen likely didn't change.
Returns -1 if the system stopped the stream (for example a display was unplugged).

```c
double t = mg_clock_now();
/* ...perform the action... */
int rc = mg_stream_wait_after(s, t, 1.0, &cap, NULL, err, sizeof err);
/* rc 0: cap shows the screen after the action. rc 1: nothing changed within 1 s. */
```

#### `mg_stream_stop`
```c
void mg_stream_stop(mg_stream *stream);
```
Stops the stream and frees it. Safe on `NULL`. Don't call it while another thread is waiting on
the same stream.

---

## Image distance (image_distance.h)

A perceptual distance between two images, from Apple's Vision feature prints: 0 for identical
images, larger the more they differ. The model version is pinned (revision 2), so a threshold
you pick won't shift after a macOS update.

Making a feature print is the expensive step: it runs a neural network, and the first call in a
process also loads the model. Comparing two prints is cheap. To compare one image against many,
make each print once and keep it.

Calibrate thresholds on real screenshot pairs taken the same way. Resampling alone moves the
distance: the same screen captured at scale 1 by two different paths measured about 0.1.

#### `mg_feature_print_create`
```c
int mg_feature_print_create(const mg_image *image, mg_feature_print **out, char *err, size_t err_len);
```
Makes a feature print from pixels in memory. Free it with `mg_feature_print_free()`.

#### `mg_feature_print_create_from_file`
```c
int mg_feature_print_create_from_file(const char *path, mg_feature_print **out, char *err, size_t err_len);
```
Same, from an image file (PNG, JPEG, …).

#### `mg_feature_print_distance`
```c
int mg_feature_print_distance(const mg_feature_print *a, const mg_feature_print *b, float *out,
                              char *err, size_t err_len);
```
Distance between two prints into `*out`. Cheap.

#### `mg_feature_print_free`
```c
void mg_feature_print_free(mg_feature_print *print);
```
Frees a print. Safe on `NULL`.

#### `mg_image_distance`
```c
int mg_image_distance(const mg_image *a, const mg_image *b, float *out, char *err, size_t err_len);
```
One shot: makes both prints, compares them, frees them.

#### `mg_image_distance_files`
```c
int mg_image_distance_files(const char *path_a, const char *path_b, float *out, char *err, size_t err_len);
```
Same, from two image files.

---

## Putting it together

An observe step that hides the overlay and sends a smaller image to the model:

```c
int32_t overlay = getppid();                       /* daemon mode */
mg_capture_options opts = { .scale = 1, .exclude_pids = &overlay, .exclude_pid_count = 1 };
mg_capture cap;
char err[256];
if (mg_capture_display(0, &opts, &cap, err, sizeof err) != 0) { /* report err */ }

mg_image img = mg_capture_image(&cap);
uint8_t *jpeg; size_t len;
mg_image_encode(&img, MG_ENCODING_JPEG, 0.8f, &jpeg, &len, err, sizeof err);
/* ...send jpeg to the model; it answers with a pixel (px, py)... */
double x, y;
mg_capture_to_point(&cap, px, py, &x, &y);         /* where to click */
free(jpeg);
mg_capture_free(&cap);
```

## Accessibility

Not wrapped: the AX API is already plain C. Include `<ApplicationServices/ApplicationServices.h>`
(already linked). Start from `AXUIElementCreateSystemWide()` or
`AXUIElementCreateApplication(pid)`, read with `AXUIElementCopyAttributeValue` /
`AXUIElementCopyMultipleAttributeValues`, act with `AXUIElementPerformAction` /
`AXUIElementSetAttributeValue`. Anything with `Create` or `Copy` in its name must be
`CFRelease`d. Full reference: the comments in `AXUIElement.h` in the macOS SDK.
