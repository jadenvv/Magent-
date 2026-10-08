#include <assert.h>
#include <float.h>
#include <stdio.h>

#include "macos/capture_layout.h"

int main(void) {
    assert(mg_bgra_layout_valid(4, 4, 16));
    assert(mg_bgra_layout_valid(4, 4, 32));
    assert(!mg_bgra_layout_valid(0, 4, 16));
    assert(!mg_bgra_layout_valid(4, 0, 16));
    assert(!mg_bgra_layout_valid(4, 4, 0));
    assert(!mg_bgra_layout_valid(4, 4, 15));
    assert(!mg_bgra_layout_valid(SIZE_MAX / 4 + 1, 1, SIZE_MAX));
    assert(!mg_bgra_layout_valid(4, SIZE_MAX / 16 + 1, 16));
    assert(mg_bgra_layout_valid(4, SIZE_MAX / 16, 16));

    size_t width = 7, height = 9;
    assert(mg_capture_dimensions(1440, 900, 2, &width, &height));
    assert(width == 2880 && height == 1800);
    assert(mg_capture_dimensions(3.25, 2.25, 2, &width, &height));
    assert(width == 7 && height == 5);
    assert(!mg_capture_dimensions(1440, 900, DBL_MAX, &width, &height));
    assert(!mg_capture_dimensions((double)SIZE_MAX, 1, 1, &width, &height));
    assert(!mg_capture_dimensions(1, (double)SIZE_MAX, 1, &width, &height));
    assert(!mg_capture_dimensions(4, 4, INFINITY, &width, &height));
    assert(!mg_capture_dimensions(4, 4, NAN, &width, &height));
    assert(!mg_capture_dimensions(4, 4, 0, &width, &height));
    assert(!mg_capture_dimensions(4, 4, -1, &width, &height));
    assert(!mg_capture_dimensions(4, 4, 0.01, &width, &height));
    assert(!mg_capture_dimensions(1e10, 1e10, 1, &width, &height));
    assert(width == 7 && height == 5); /* Failure leaves dimensions unchanged. */
    puts("ok");
    return 0;
}
