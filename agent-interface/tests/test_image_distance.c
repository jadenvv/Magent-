// Checks for platform/image_distance.h. Run with `make test`.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "image_distance.h"

enum { W = 256, H = 192 };

static int failures = 0;
#define CHECK(cond, ...)                                       \
    do {                                                       \
        if (!(cond)) {                                         \
            failures++;                                        \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                      \
            fputc('\n', stderr);                               \
        }                                                      \
    } while (0)

/* White image with a dark square at (sx, sy); `stride` lets rows be padded. */
static uint8_t *make_image(mg_pixel_format fmt, size_t stride, int sx, int sy, int side) {
    uint8_t *px = malloc(stride * H);
    memset(px, 0x7f, stride * H); /* padding bytes: garbage the backend must skip */
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            int in_square = x >= sx && x < sx + side && y >= sy && y < sy + side;
            uint8_t r = in_square ? 20 : 255, g = in_square ? 40 : 255, b = in_square ? 200 : 255;
            uint8_t *p = px + (size_t)y * stride + (size_t)x * 4;
            if (fmt == MG_PIXEL_BGRA8) { p[0] = b; p[1] = g; p[2] = r; }
            else                       { p[0] = r; p[1] = g; p[2] = b; }
            p[3] = 255;
        }
    }
    return px;
}

static mg_image wrap(const uint8_t *px, mg_pixel_format fmt, size_t stride) {
    return (mg_image){ .pixels = px, .width = W, .height = H, .bytes_per_row = stride, .format = fmt };
}

int main(void) {
    char err[256];
    float d_same = -1, d_diff = -1, d_fmt = -1, d_pad = -1, d = -1;

    uint8_t *a      = make_image(MG_PIXEL_BGRA8, W * 4, 20, 20, 80);
    uint8_t *a_copy = make_image(MG_PIXEL_BGRA8, W * 4, 20, 20, 80);
    uint8_t *b      = make_image(MG_PIXEL_BGRA8, W * 4, 150, 90, 80);
    uint8_t *a_rgba = make_image(MG_PIXEL_RGBA8, W * 4, 20, 20, 80);
    uint8_t *a_pad  = make_image(MG_PIXEL_BGRA8, W * 4 + 64, 20, 20, 80);
    mg_image ia = wrap(a, MG_PIXEL_BGRA8, W * 4);

    CHECK(mg_image_distance(&ia, &(mg_image){0}, &d, err, sizeof err) == -1, "accepted an empty image");
    CHECK(mg_image_distance(&ia, &ia, NULL, err, sizeof err) == -1, "accepted a NULL distance output");
    const char invalid_path[] = { (char)0xff, 0 };
    mg_feature_print *invalid_print = NULL;
    CHECK(mg_feature_print_create_from_file(invalid_path, &invalid_print, err, sizeof err) == -1,
          "accepted an invalid UTF-8 path");

    mg_image ia_copy = wrap(a_copy, MG_PIXEL_BGRA8, W * 4);
    CHECK(mg_image_distance(&ia, &ia_copy, &d_same, err, sizeof err) == 0, "%s", err);
    mg_image ib = wrap(b, MG_PIXEL_BGRA8, W * 4);
    CHECK(mg_image_distance(&ia, &ib, &d_diff, err, sizeof err) == 0, "%s", err);
    /* Same picture in the other byte order, and with padded rows: should match `a`. */
    mg_image ia_rgba = wrap(a_rgba, MG_PIXEL_RGBA8, W * 4);
    CHECK(mg_image_distance(&ia, &ia_rgba, &d_fmt, err, sizeof err) == 0, "%s", err);
    mg_image ia_pad = wrap(a_pad, MG_PIXEL_BGRA8, W * 4 + 64);
    CHECK(mg_image_distance(&ia, &ia_pad, &d_pad, err, sizeof err) == 0, "%s", err);

    printf("identical       %.4f\n", d_same);
    printf("rgba vs bgra    %.4f\n", d_fmt);
    printf("padded rows     %.4f\n", d_pad);
    printf("square moved    %.4f\n", d_diff);
    CHECK(d_same < 1e-4f, "identical images: distance %f", d_same);
    CHECK(d_fmt < 1e-4f, "pixel formats disagree: distance %f", d_fmt);
    CHECK(d_pad < 1e-4f, "row padding leaked into the image: distance %f", d_pad);
    CHECK(d_diff > d_same + 1e-3f, "different images not further apart (%f vs %f)", d_diff, d_same);

    /* Reusing prints gives the same answer as the one-shot helper. */
    mg_feature_print *pa = NULL, *pb = NULL;
    CHECK(mg_feature_print_create(&ia, &pa, err, sizeof err) == 0, "%s", err);
    CHECK(mg_feature_print_create(&ib, &pb, err, sizeof err) == 0, "%s", err);
    CHECK(mg_feature_print_distance(pa, pb, &d, err, sizeof err) == 0 && d == d_diff, "cached print gave %f, want %f", d, d_diff);
    mg_feature_print_free(pa);
    mg_feature_print_free(pb);

    err[0] = '\0';
    CHECK(mg_image_distance_files("/nonexistent/a.png", "/nonexistent/b.png", &d, err, sizeof err) == -1, "missing file accepted");
    CHECK(err[0] != '\0', "no error message for missing file");

    free(a); free(a_copy); free(b); free(a_rgba); free(a_pad);
    if (failures) { fprintf(stderr, "%d check(s) failed\n", failures); return 1; }
    puts("ok");
    return 0;
}
