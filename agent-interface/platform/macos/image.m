// macOS backend for image.h, plus helpers shared by the other platform files. Compiled with ARC.

#import <ImageIO/ImageIO.h>

#include "cgimage.h"

void mg_set_err(char *err, size_t err_len, NSString *message) {
    if (err && err_len > 0) strlcpy(err, message.UTF8String ? message.UTF8String : "unknown error", err_len);
}

void mg_set_ns_err(char *err, size_t err_len, NSString *context, NSError *error) {
    NSString *detail = error.localizedDescription ? error.localizedDescription : @"unknown error";
    mg_set_err(err, err_len, [NSString stringWithFormat:@"%@: %@", context, detail]);
}

CGImageRef mg_cgimage_create(const mg_image *image) {
    if (!image || !image->pixels || image->width == 0 || image->height == 0 ||
        image->width > SIZE_MAX / 4 || image->bytes_per_row < image->width * 4 ||
        image->height > SIZE_MAX / image->bytes_per_row ||
        (image->format != MG_PIXEL_BGRA8 && image->format != MG_PIXEL_RGBA8))
        return NULL;
    CGBitmapInfo info = image->format == MG_PIXEL_BGRA8
        ? (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little
        : (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big;
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(NULL, image->pixels, image->bytes_per_row * image->height, NULL);
    if (!provider) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!space) {
        CGDataProviderRelease(provider);
        return NULL;
    }
    CGImageRef cg = CGImageCreate(image->width, image->height, 8, 32, image->bytes_per_row, space, info,
                                  provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return cg;
}

static CFStringRef type_for(mg_encoding encoding) {
    return encoding == MG_ENCODING_JPEG ? CFSTR("public.jpeg") : CFSTR("public.png");
}

// Encodes into either a data buffer or a file, whichever destination is given.
static int encode(const mg_image *image, mg_encoding encoding, float quality, CGImageDestinationRef dest,
                  char *err, size_t err_len) {
    CGImageRef cg = mg_cgimage_create(image);
    if (!cg) {
        mg_set_err(err, err_len, @"invalid image");
        return -1;
    }
    NSDictionary *props = encoding == MG_ENCODING_JPEG
        ? @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(quality)}
        : @{};
    CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)props);
    bool ok = CGImageDestinationFinalize(dest);
    CGImageRelease(cg);
    if (!ok) {
        mg_set_err(err, err_len, @"image encoding failed");
        return -1;
    }
    return 0;
}

int mg_image_encode(const mg_image *image, mg_encoding encoding, float quality,
                    uint8_t **out, size_t *out_len, char *err, size_t err_len) {
    if (!out || !out_len) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        NSMutableData *data = [NSMutableData data];
        CGImageDestinationRef dest =
            CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, type_for(encoding), 1, NULL);
        if (!dest) {
            mg_set_err(err, err_len, @"couldn't create image encoder");
            return -1;
        }
        int rc = encode(image, encoding, quality, dest, err, err_len);
        CFRelease(dest);
        if (rc != 0) return rc;
        *out = malloc(data.length);
        if (!*out) {
            mg_set_err(err, err_len, @"out of memory");
            return -1;
        }
        memcpy(*out, data.bytes, data.length);
        *out_len = data.length;
        return 0;
    }
}

int mg_image_write(const mg_image *image, const char *path, mg_encoding encoding, float quality,
                   char *err, size_t err_len) {
    if (!path) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path];
        if (!p) {
            mg_set_err(err, err_len, @"invalid UTF-8 path");
            return -1;
        }
        NSURL *url = [NSURL fileURLWithPath:p];
        CGImageDestinationRef dest =
            CGImageDestinationCreateWithURL((__bridge CFURLRef)url, type_for(encoding), 1, NULL);
        if (!dest) {
            mg_set_err(err, err_len, [NSString stringWithFormat:@"can't write %s", path]);
            return -1;
        }
        int rc = encode(image, encoding, quality, dest, err, err_len);
        CFRelease(dest);
        return rc;
    }
}
