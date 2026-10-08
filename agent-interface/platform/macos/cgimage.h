// Internal helpers shared by the macOS platform files. Not part of the C interface.
#ifndef MG_MACOS_CGIMAGE_H
#define MG_MACOS_CGIMAGE_H

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include "image.h"

/* Wraps the pixels without copying; they must outlive the CGImage. NULL on failure. */
CGImageRef mg_cgimage_create(const mg_image *image);

void mg_set_err(char *err, size_t err_len, NSString *message);
void mg_set_ns_err(char *err, size_t err_len, NSString *context, NSError *error);

#endif
