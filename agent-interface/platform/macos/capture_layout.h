/* Internal bounds checks shared by screenshot and stream buffer handling. */
#ifndef MG_CAPTURE_LAYOUT_H
#define MG_CAPTURE_LAYOUT_H

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

static inline bool mg_bgra_layout_valid(size_t width, size_t height, size_t stride) {
    return width > 0 && height > 0 && width <= SIZE_MAX / 4 &&
           stride >= width * 4 && height <= SIZE_MAX / stride;
}

static inline bool mg_capture_dimensions(double point_width, double point_height, double scale,
                                          size_t *width, size_t *height) {
    double w = round(point_width * scale), h = round(point_height * scale);
    // SIZE_MAX rounds up when converted to double on 64-bit targets. Exclude that boundary
    // before casting; converting an out-of-range floating value to size_t is undefined.
    if (!isfinite(w) || !isfinite(h) || w < 1 || h < 1 ||
        w >= (double)SIZE_MAX || h >= (double)SIZE_MAX)
        return false;
    size_t pixel_width = (size_t)w, pixel_height = (size_t)h;
    if (pixel_width > SIZE_MAX / 4 ||
        !mg_bgra_layout_valid(pixel_width, pixel_height, pixel_width * 4))
        return false;
    *width = pixel_width;
    *height = pixel_height;
    return true;
}

#endif
