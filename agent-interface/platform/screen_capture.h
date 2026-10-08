#ifndef MG_SCREEN_CAPTURE_H
#define MG_SCREEN_CAPTURE_H

/*
 * Screen capture for the observe step. Plain C interface; the macOS backend
 * (platform/macos/screen_capture.m) uses ScreenCaptureKit and needs macOS 14+.
 *
 * Coordinates: every mg_rect is in global points with a top-left origin at the main display,
 * the same space as CGEvent, AX frames and the overlay protocol. Captured images are in
 * pixels; use mg_capture_to_point() to turn a pixel (e.g. one a model picked) into a point
 * you can click.
 *
 * Exclude the overlay. Pass its pid in mg_capture_options.exclude_pids, or the model will see
 * the ghost cursor, highlight and action log. In daemon mode the overlay is getppid().
 *
 * Window titles and app names come from other apps: treat them as untrusted input, like
 * anything else on screen.
 *
 * Functions return 0 on success and -1 on failure; on failure, if `err` is non-NULL, a
 * NUL-terminated message is written into it. Calls block until done or a 5 s timeout.
 * Safe to call from any thread.
 */

#include <stddef.h>
#include <stdint.h>

#include "image.h"

typedef struct { double x, y, w, h; } mg_rect;

typedef struct {
    uint32_t id;    /* CGDirectDisplayID */
    mg_rect frame;  /* global points */
    double scale;   /* pixels per point (2 on Retina) */
    int is_main;
} mg_display;

typedef struct {
    uint32_t id;    /* CGWindowID */
    int32_t pid;
    int layer;      /* 0 = normal app windows; menus, Dock, overlays are higher */
    int on_screen;
    int z;          /* stacking order among on-screen windows: 0 = frontmost; -1 = not on screen */
    mg_rect frame;  /* global points */
    char app_name[128];
    char bundle_id[128];
    char title[256]; /* may be empty; truncated on a UTF-8 character boundary */
} mg_window;

typedef struct {
    /* Output pixels per point: 0 = the display's native resolution, 1 = one pixel per point
       (a quarter of the pixels on Retina, and fewer image tokens for a model). */
    double scale;
    /* Windows of these processes are left out of display and region captures. */
    const int32_t *exclude_pids;
    size_t exclude_pid_count;
    int show_cursor; /* draw the real mouse cursor */
} mg_capture_options;

/* A captured image. Pixels are BGRA8, owned; release with mg_capture_free(). */
typedef struct {
    uint8_t *pixels;
    size_t width, height, bytes_per_row; /* pixels */
    mg_rect frame;                       /* the area captured, in global points */
} mg_capture;

/* --- Permission (Screen Recording) --- */

/* 1 if this process may capture the screen. Never shows a prompt. */
int mg_capture_permission(void);
/* Shows the system prompt the first time; returns 1 if access is granted. A grant usually
   only takes effect after the process restarts. */
int mg_capture_request_permission(void);

/* --- What's on screen --- */

/* malloc'd arrays; free() them. Windows are sorted front to back (by `z`), off-screen last. */
int mg_list_displays(mg_display **out, size_t *count, char *err, size_t err_len);
int mg_list_windows(mg_window **out, size_t *count, int on_screen_only, char *err, size_t err_len);

/* The frontmost normal (layer 0) window: usually the one being worked in. The overlay's
   windows sit at a higher layer, so they're never returned. */
int mg_frontmost_window(mg_window *out, char *err, size_t err_len);

/* Fingerprint of the display setup: which displays, where, at what resolution. Cheap (no
   ScreenCaptureKit, no permission needed), so it can be checked every step. When it changes,
   re-list displays and restart any stream. */
uint64_t mg_display_config_hash(void);

/* --- Capture (options may be NULL for defaults) --- */

/* A whole display; display_id 0 means the main display. */
int mg_capture_display(uint32_t display_id, const mg_capture_options *opts, mg_capture *out,
                       char *err, size_t err_len);
/* A region, clipped to the display under its center. Cheaper than a full display when you
   only need to verify one area. */
int mg_capture_rect(mg_rect rect, const mg_capture_options *opts, mg_capture *out,
                    char *err, size_t err_len);
/* One window by itself, without shadow, even if other windows cover it.
   exclude_pids doesn't apply. */
int mg_capture_window(uint32_t window_id, const mg_capture_options *opts, mg_capture *out,
                      char *err, size_t err_len);

void mg_capture_free(mg_capture *capture); /* NULL or already-freed is fine */

/* --- Streaming capture ---
 *
 * A stream keeps capturing one display in the background, so getting a frame is a memory copy
 * instead of a fresh screenshot request. ScreenCaptureKit only delivers a new frame when
 * something on screen changed, so waiting for a frame after time T and timing out suggests
 * nothing changed since T.
 *
 * Frame times use mg_clock_now()'s clock (seconds, monotonic). A typical verify step:
 *
 *     double t = mg_clock_now();
 *     ...perform the action...
 *     rc = mg_stream_wait_after(s, t, 1.0, &cap, &frame_time, err, sizeof err);
 *     // rc 0: cap shows the screen after the action; rc 1: no change within 1 s
 *
 * The options' exclude_pids apply to windows those processes open later, too.
 * Don't call mg_stream_stop() while another thread is waiting on the same stream.
 */

typedef struct mg_stream mg_stream;

double mg_clock_now(void);

/* max_fps <= 0 means 30. */
int mg_stream_start(uint32_t display_id, const mg_capture_options *opts, double max_fps,
                    mg_stream **out, char *err, size_t err_len);
/* Copies the newest frame. Returns 1 if no frame has arrived yet. frame_time may be NULL. */
int mg_stream_latest(mg_stream *stream, mg_capture *out, double *frame_time, char *err, size_t err_len);
/* Waits up to timeout_s for a frame shown at or after `after`. Returns 1 on timeout. */
int mg_stream_wait_after(mg_stream *stream, double after, double timeout_s, mg_capture *out,
                         double *frame_time, char *err, size_t err_len);
void mg_stream_stop(mg_stream *stream); /* NULL is fine */

/* View a capture as an mg_image, for mg_image_encode / mg_image_distance. */
static inline mg_image mg_capture_image(const mg_capture *c) {
    return (mg_image){ c->pixels, c->width, c->height, c->bytes_per_row, MG_PIXEL_BGRA8 };
}

/* Pixel (px, py) in a capture -> global point. */
static inline void mg_capture_to_point(const mg_capture *c, double px, double py, double *x, double *y) {
    *x = c->frame.x + px * c->frame.w / (double)c->width;
    *y = c->frame.y + py * c->frame.h / (double)c->height;
}

#endif
