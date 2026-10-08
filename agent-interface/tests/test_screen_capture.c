// Checks for platform/screen_capture.h and platform/image.h. Run with `make test`.
// Live capture checks need Screen Recording permission for the terminal running them; without
// it they print SKIP. Nothing captured is written to disk or printed beyond sizes.
// Pass --offline to check image validation/encoding without a changing desktop.

#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "screen_capture.h"

static int failures = 0;
#define CHECK(cond, ...)                                         \
    do {                                                         \
        if (!(cond)) {                                           \
            failures++;                                          \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                        \
            fputc('\n', stderr);                                 \
        }                                                        \
    } while (0)

static int near(double a, double b) { return fabs(a - b) < 0.5; }

/* Mean absolute difference per color channel, 0..255. */
static double mean_abs_diff(const uint8_t *a, size_t a_stride, const uint8_t *b, size_t b_stride, size_t w, size_t h) {
    double sum = 0;
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w * 4; x++)
            if (x % 4 != 3) sum += abs(a[y * a_stride + x] - b[y * b_stride + x]);
    return sum / (double)(w * h * 3);
}

static void test_offline(void) {
    char err[256];
    uint8_t px[4 * 4 * 4];
    memset(px, 0x80, sizeof px);
    mg_image img = { px, 4, 4, 16, MG_PIXEL_BGRA8 };

    uint8_t *png = NULL, *jpg = NULL;
    size_t png_len = 0, jpg_len = 0;
    CHECK(mg_image_encode(&img, MG_ENCODING_PNG, 0, &png, &png_len, err, sizeof err) == 0, "%s", err);
    CHECK(png_len > 8 && memcmp(png, "\x89PNG", 4) == 0, "not a PNG");
    CHECK(mg_image_encode(&img, MG_ENCODING_JPEG, 0.7f, &jpg, &jpg_len, err, sizeof err) == 0, "%s", err);
    CHECK(jpg_len > 3 && jpg[0] == 0xFF && jpg[1] == 0xD8, "not a JPEG");
    free(png);
    free(jpg);

    mg_image bad = { NULL, 4, 4, 16, MG_PIXEL_BGRA8 };
    CHECK(mg_image_encode(&bad, MG_ENCODING_PNG, 0, &png, &png_len, err, sizeof err) == -1, "encoded a NULL image");

    bad = img;
    bad.width = SIZE_MAX / 4 + 1;
    CHECK(mg_image_encode(&bad, MG_ENCODING_PNG, 0, &png, &png_len, err, sizeof err) == -1, "accepted width overflow");
    bad = img;
    bad.height = SIZE_MAX / bad.bytes_per_row + 1;
    CHECK(mg_image_encode(&bad, MG_ENCODING_PNG, 0, &png, &png_len, err, sizeof err) == -1, "accepted buffer size overflow");
    bad = img;
    bad.bytes_per_row = 15;
    CHECK(mg_image_encode(&bad, MG_ENCODING_PNG, 0, &png, &png_len, err, sizeof err) == -1, "accepted a short row");
    bad = img;
    bad.format = (mg_pixel_format)99;
    CHECK(mg_image_encode(&bad, MG_ENCODING_PNG, 0, &png, &png_len, err, sizeof err) == -1, "accepted an invalid pixel format");
    const char invalid_path[] = { (char)0xff, 0 };
    CHECK(mg_image_write(&img, invalid_path, MG_ENCODING_PNG, 0, err, sizeof err) == -1, "accepted an invalid UTF-8 path");
    CHECK(mg_capture_rect((mg_rect){ NAN, 0, 1, 1 }, NULL, &((mg_capture){0}), err, sizeof err) == -1,
          "accepted a non-finite capture rectangle");

    /* A 400x200 px capture of a 200x100 pt area at (100,50): pixel (400,200) is point (300,150). */
    mg_capture c = { .width = 400, .height = 200, .frame = { 100, 50, 200, 100 } };
    double x, y;
    mg_capture_to_point(&c, 400, 200, &x, &y);
    CHECK(x == 300 && y == 150, "pixel->point gave (%f, %f)", x, y);
    mg_capture_free(&c);
    mg_capture_free(&c); /* twice is fine */
}

static void test_live(void) {
    char err[256];

    mg_display *displays = NULL;
    size_t n_displays = 0;
    CHECK(mg_list_displays(&displays, &n_displays, err, sizeof err) == 0, "%s", err);
    if (!displays || n_displays == 0) { CHECK(0, "no displays"); return; }

    const mg_display *main_display = NULL;
    for (size_t i = 0; i < n_displays; i++)
        if (displays[i].is_main) main_display = &displays[i];
    CHECK(main_display != NULL, "no main display");
    if (!main_display) { free(displays); return; }
    mg_rect f = main_display->frame;
    CGRect cg = CGDisplayBounds(CGMainDisplayID());
    printf("main display    %.0fx%.0f pt at (%.0f,%.0f), scale %.1f\n", f.w, f.h, f.x, f.y, main_display->scale);
    /* Confirms ScreenCaptureKit frames are in the same top-left space as CGEvent. */
    CHECK(f.x == cg.origin.x && f.y == cg.origin.y && f.w == cg.size.width && f.h == cg.size.height,
          "display frame doesn't match CGDisplayBounds");

    mg_capture_options one_x = { .scale = 1 };
    mg_capture full = {0};
    CHECK(mg_capture_display(0, &one_x, &full, err, sizeof err) == 0, "%s", err);
    printf("display @1x     %zux%zu px\n", full.width, full.height);
    CHECK(near((double)full.width, f.w) && near((double)full.height, f.h), "1x capture should be one pixel per point");

    mg_capture native = {0};
    CHECK(mg_capture_display(0, NULL, &native, err, sizeof err) == 0, "%s", err);
    printf("display native  %zux%zu px\n", native.width, native.height);
    CHECK(near((double)native.width, f.w * main_display->scale), "native capture width");
    mg_capture_free(&native);

    /* A region must show the same pixels as that part of the full capture. If sourceRect were
       in a different coordinate space, these would differ by a lot. Compared pixel by pixel:
       the two are downscaled from 2x by different paths, and a feature print is sensitive to
       that resampling difference (about 0.1) even when the content is identical. */
    mg_rect r = { f.x + 100, f.y + 150, 300, 200 };
    mg_capture region = {0};
    CHECK(mg_capture_rect(r, &one_x, &region, err, sizeof err) == 0, "%s", err);
    CHECK(region.width == 300 && region.height == 200, "region is %zux%zu", region.width, region.height);
    if (full.pixels && full.width >= 400 && full.height >= 350 &&
        region.pixels && region.width == 300 && region.height == 200) {
        const uint8_t *crop = full.pixels + 150 * full.bytes_per_row + 100 * 4;
        double diff = mean_abs_diff(crop, full.bytes_per_row, region.pixels, region.bytes_per_row, 300, 200);
        printf("region vs crop  mean diff %.2f / 255\n", diff);
        CHECK(diff < 2.0, "region doesn't match the same area of the full capture");
    }
    mg_capture_free(&region);
    mg_capture_free(&full);

    /* Partly off the right edge (center still on screen): clipped to the display. */
    mg_rect edge = { f.x + f.w - 60, f.y + 10, 100, 40 };
    mg_capture clipped = {0};
    CHECK(mg_capture_rect(edge, &one_x, &clipped, err, sizeof err) == 0, "%s", err);
    CHECK(clipped.frame.w == 60 && clipped.width == 60, "clip gave %.0f pt / %zu px", clipped.frame.w, clipped.width);
    mg_capture_free(&clipped);

    mg_window *windows = NULL;
    size_t n_windows = 0;
    CHECK(mg_list_windows(&windows, &n_windows, 1, err, sizeof err) == 0, "%s", err);
    printf("windows         %zu on screen\n", n_windows);
    const mg_window *target = NULL;
    for (size_t i = 0; i < n_windows && !target; i++)
        if (windows[i].layer == 0 && windows[i].frame.w >= 100 && windows[i].frame.h >= 100) target = &windows[i];
    if (target) {
        mg_capture win = {0};
        CHECK(mg_capture_window(target->id, &one_x, &win, err, sizeof err) == 0, "%s", err);
        printf("window @1x      %zux%zu px for a %.0fx%.0f pt window\n", win.width, win.height, target->frame.w, target->frame.h);
        CHECK(fabs((double)win.width - target->frame.w) <= 2 && fabs((double)win.height - target->frame.h) <= 2,
              "window capture size doesn't match its frame");
        mg_capture_free(&win);
    } else {
        puts("SKIP window capture: no normal window on screen");
    }
    CHECK(mg_capture_window(0xFFFFFFF0u, NULL, &(mg_capture){0}, err, sizeof err) == -1, "captured a nonexistent window");

    free(windows);
    free(displays);
}

static void test_stacking_and_displays(void) {
    char err[256];

    uint64_t h1 = mg_display_config_hash(), h2 = mg_display_config_hash();
    CHECK(h1 != 0 && h1 == h2, "display hash unstable: %llx vs %llx", (unsigned long long)h1, (unsigned long long)h2);

    mg_window *windows = NULL;
    size_t n = 0;
    CHECK(mg_list_windows(&windows, &n, 0, err, sizeof err) == 0, "%s", err);
    int sorted = 1, seen_offscreen = 0;
    for (size_t i = 0; i < n; i++) {
        if (windows[i].z < 0) seen_offscreen = 1;
        else if (seen_offscreen || (i > 0 && windows[i - 1].z >= windows[i].z)) sorted = 0;
    }
    CHECK(sorted, "windows not sorted front to back with off-screen last");
    CHECK(n == 0 || windows[0].z == 0, "first window isn't the frontmost");

    mg_window front;
    if (mg_frontmost_window(&front, err, sizeof err) == 0) {
        printf("frontmost       layer %d, z %d, %.0fx%.0f pt\n", front.layer, front.z, front.frame.w, front.frame.h);
        CHECK(front.layer == 0, "frontmost window isn't a normal window");
        /* Cross-check against Accessibility's idea of the focused app, when we're allowed to ask. */
        if (AXIsProcessTrusted()) {
            AXUIElementRef sys = AXUIElementCreateSystemWide(), app = NULL;
            if (AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute, (CFTypeRef *)&app) == kAXErrorSuccess) {
                pid_t pid = 0;
                AXUIElementGetPid(app, &pid);
                CHECK(pid == front.pid, "frontmost window pid %d, focused app pid %d", front.pid, pid);
                CFRelease(app);
            }
            CFRelease(sys);
        } else {
            puts("SKIP frontmost vs focused app: no Accessibility permission");
        }
    } else {
        printf("SKIP frontmost window: %s\n", err);
    }
    free(windows);
}

static void test_stream(void) {
    char err[256];
    mg_capture_options one_x = { .scale = 1 };
    mg_stream *stream = NULL;
    double t0 = mg_clock_now();
    CHECK(mg_stream_start(0, &one_x, 30, &stream, err, sizeof err) == 0, "%s", err);
    if (!stream) return;
    printf("stream start    %.0f ms\n", (mg_clock_now() - t0) * 1000);

    /* The first frame always arrives, changed screen or not. */
    mg_capture first = {0};
    double t_first = 0;
    int rc = mg_stream_wait_after(stream, -INFINITY, 2.0, &first, &t_first, err, sizeof err);
    CHECK(rc == 0, "no first frame (rc %d): %s", rc, err);
    if (rc == 0) {
        mg_display *displays = NULL;
        size_t n = 0;
        mg_list_displays(&displays, &n, err, sizeof err);
        for (size_t i = 0; i < n; i++)
            if (displays[i].is_main)
                CHECK(near((double)first.width, displays[i].frame.w) && near((double)first.height, displays[i].frame.h),
                      "stream frame %zux%zu at 1x", first.width, first.height);
        free(displays);
        CHECK(t_first <= mg_clock_now() && t_first > t0 - 1, "frame time %f outside [%f, now]", t_first, t0);

        /* The stream's pixels should match a one-off screenshot of the same screen. */
        mg_capture shot = {0};
        if (mg_capture_display(0, &one_x, &shot, err, sizeof err) == 0) {
            mg_capture now = {0};
            if (mg_stream_latest(stream, &now, NULL, err, sizeof err) == 0) {
                if (now.width == shot.width && now.height == shot.height) {
                    double diff = mean_abs_diff(now.pixels, now.bytes_per_row, shot.pixels, shot.bytes_per_row, now.width, now.height);
                    printf("stream vs shot  mean diff %.2f / 255\n", diff);
                    CHECK(diff < 3.0, "stream frame doesn't match a screenshot");
                } else {
                    CHECK(0, "stream and screenshot dimensions differ");
                }
                mg_capture_free(&now);
            }
        }
        mg_capture_free(&shot);

        double t1 = mg_clock_now();
        mg_capture copy = {0};
        CHECK(mg_stream_latest(stream, &copy, NULL, err, sizeof err) == 0, "%s", err);
        printf("stream latest   %.1f ms (copy only)\n", (mg_clock_now() - t1) * 1000);
        mg_capture_free(&copy);
    }
    mg_capture_free(&first);

    /* Waiting for a frame newer than "now" either gets one (something moved) or times out. */
    mg_capture later = {0};
    rc = mg_stream_wait_after(stream, mg_clock_now(), 0.3, &later, NULL, err, sizeof err);
    CHECK(rc == 0 || rc == 1, "wait_after failed: %s", err);
    printf("wait_after 0.3s %s\n", rc == 0 ? "got a newer frame" : "timed out (no change)");
    mg_capture_free(&later);

    mg_stream_stop(stream);
    mg_stream_stop(NULL);
}

int main(int argc, char **argv) {
    int offline = argc == 2 && strcmp(argv[1], "--offline") == 0;
    if (argc > 1 && !offline) {
        fprintf(stderr, "usage: %s [--offline]\n", argv[0]);
        return 2;
    }
    test_offline();
    if (offline)
        puts("SKIP live capture: offline checks requested");
    else if (mg_capture_permission()) {
        test_live();
        test_stacking_and_displays();
        test_stream();
    }
    else
        puts("SKIP live capture: this process has no Screen Recording permission");

    if (failures) { fprintf(stderr, "%d check(s) failed\n", failures); return 1; }
    puts("ok");
    return 0;
}
