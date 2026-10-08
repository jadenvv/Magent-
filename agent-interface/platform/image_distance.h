#ifndef MG_IMAGE_DISTANCE_H
#define MG_IMAGE_DISTANCE_H

/*
 * Perceptual distance between two images: 0 for identical images, larger the more they differ.
 * Plain C interface; the macOS backend (platform/macos/image_distance.m) uses Vision's
 * VNGenerateImageFeaturePrintRequest, pinned to revision 2 so that distance thresholds don't
 * shift when the OS updates its default model.
 *
 * Making a feature print is the expensive step (it runs a neural network; the first call in a
 * process also loads the model). Computing a distance between two prints is cheap. To compare
 * one image against many, make each print once and keep it.
 *
 * All functions return 0 on success and -1 on failure. On failure, if `err` is non-NULL, a
 * message is written into it (always NUL-terminated, truncated to `err_len`).
 * Safe to call from any thread.
 */

#include "image.h" /* mg_image; its pixels are only read during each call */

typedef struct mg_feature_print mg_feature_print;

int mg_feature_print_create(const mg_image *image, mg_feature_print **out, char *err, size_t err_len);
int mg_feature_print_create_from_file(const char *path, mg_feature_print **out, char *err, size_t err_len);
int mg_feature_print_distance(const mg_feature_print *a, const mg_feature_print *b, float *out, char *err, size_t err_len);
void mg_feature_print_free(mg_feature_print *print); /* NULL is fine */

/* One-shot helpers: make both prints, compare, free. */
int mg_image_distance(const mg_image *a, const mg_image *b, float *out, char *err, size_t err_len);
int mg_image_distance_files(const char *path_a, const char *path_b, float *out, char *err, size_t err_len);

#endif
