// macOS backend for image_distance.h, using Vision feature prints. Compiled with ARC.

#import <Vision/Vision.h>

#include "cgimage.h"
#include "image_distance.h"

// Runs the request on a handler and hands back the observation retained (+1) as the opaque
// C handle; mg_feature_print_free balances it.
static int run_request(VNImageRequestHandler *handler, mg_feature_print **out, char *err, size_t err_len) {
    VNGenerateImageFeaturePrintRequest *request = [[VNGenerateImageFeaturePrintRequest alloc] init];
    // Pinned: distances from different revisions aren't comparable, and the default changes
    // with OS releases. Revision 2 needs macOS 14, which the overlay already requires.
    request.revision = VNGenerateImageFeaturePrintRequestRevision2;

    NSError *error = nil;
    if (![handler performRequests:@[request] error:&error]) {
        mg_set_ns_err(err, err_len, @"feature print request failed", error);
        return -1;
    }
    VNFeaturePrintObservation *observation = request.results.firstObject;
    if (!observation) {
        mg_set_err(err, err_len, @"feature print request returned no result");
        return -1;
    }
    *out = (__bridge_retained void *)observation;
    return 0;
}

int mg_feature_print_create(const mg_image *image, mg_feature_print **out, char *err, size_t err_len) {
    if (!out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    // A C caller has no autorelease pool; without this, every call would leak until exit.
    @autoreleasepool {
        // No copy: the request runs synchronously below, while the caller's pixels are valid.
        CGImageRef cg = mg_cgimage_create(image);
        if (!cg) {
            mg_set_err(err, err_len, @"invalid image");
            return -1;
        }
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        int rc = run_request(handler, out, err, err_len);
        CGImageRelease(cg);
        return rc;
    }
}

int mg_feature_print_create_from_file(const char *path, mg_feature_print **out, char *err, size_t err_len) {
    if (!path || !out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path];
        if (!p) {
            mg_set_err(err, err_len, @"invalid UTF-8 path");
            return -1;
        }
        if (![[NSFileManager defaultManager] isReadableFileAtPath:p]) {
            mg_set_err(err, err_len, [NSString stringWithFormat:@"can't read %@", p]);
            return -1;
        }
        VNImageRequestHandler *handler =
            [[VNImageRequestHandler alloc] initWithURL:[NSURL fileURLWithPath:p] options:@{}];
        return run_request(handler, out, err, err_len);
    }
}

int mg_feature_print_distance(const mg_feature_print *a, const mg_feature_print *b, float *out, char *err, size_t err_len) {
    if (!a || !b || !out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        VNFeaturePrintObservation *pa = (__bridge VNFeaturePrintObservation *)(const void *)a;
        VNFeaturePrintObservation *pb = (__bridge VNFeaturePrintObservation *)(const void *)b;
        NSError *error = nil;
        if (![pa computeDistance:out toFeaturePrintObservation:pb error:&error]) {
            mg_set_ns_err(err, err_len, @"computeDistance failed", error);
            return -1;
        }
        return 0;
    }
}

void mg_feature_print_free(mg_feature_print *print) {
    if (print) CFRelease((CFTypeRef)print);
}

int mg_image_distance(const mg_image *a, const mg_image *b, float *out, char *err, size_t err_len) {
    if (!out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    mg_feature_print *pa = NULL, *pb = NULL;
    int rc = -1;
    if (mg_feature_print_create(a, &pa, err, err_len) == 0 &&
        mg_feature_print_create(b, &pb, err, err_len) == 0)
        rc = mg_feature_print_distance(pa, pb, out, err, err_len);
    mg_feature_print_free(pa);
    mg_feature_print_free(pb);
    return rc;
}

int mg_image_distance_files(const char *path_a, const char *path_b, float *out, char *err, size_t err_len) {
    if (!out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    mg_feature_print *pa = NULL, *pb = NULL;
    int rc = -1;
    if (mg_feature_print_create_from_file(path_a, &pa, err, err_len) == 0 &&
        mg_feature_print_create_from_file(path_b, &pb, err, err_len) == 0)
        rc = mg_feature_print_distance(pa, pb, out, err, err_len);
    mg_feature_print_free(pa);
    mg_feature_print_free(pb);
    return rc;
}
