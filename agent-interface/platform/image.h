#ifndef MG_IMAGE_H
#define MG_IMAGE_H

/*
 * Image types shared by the platform layer (capture, image distance), plus encoding for
 * logging screenshots or sending them to a model.
 *
 * Functions return 0 on success and -1 on failure; on failure, if `err` is non-NULL, a
 * NUL-terminated message is written into it (truncated to `err_len`).
 */

#include <stddef.h>
#include <stdint.h>

typedef enum {
    MG_PIXEL_BGRA8, /* byte order B,G,R,A: what screen capture produces */
    MG_PIXEL_RGBA8, /* byte order R,G,B,A */
} mg_pixel_format;

/* An image in memory, not owned. Alpha is ignored. */
typedef struct {
    const uint8_t *pixels;
    size_t width;
    size_t height;
    size_t bytes_per_row; /* >= width * 4; rows may be padded */
    mg_pixel_format format;
} mg_image;

typedef enum {
    MG_ENCODING_PNG,  /* lossless; `quality` ignored */
    MG_ENCODING_JPEG, /* `quality` 0..1; much smaller, fine for a model looking at a screen */
} mg_encoding;

/* Encodes into a malloc'd buffer; free(*out) when done. */
int mg_image_encode(const mg_image *image, mg_encoding encoding, float quality,
                    uint8_t **out, size_t *out_len, char *err, size_t err_len);

/* Writes an encoded file, e.g. for a per-step screenshot trace. */
int mg_image_write(const mg_image *image, const char *path, mg_encoding encoding, float quality,
                   char *err, size_t err_len);

#endif
