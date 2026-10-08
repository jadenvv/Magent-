// macOS backend for screen_capture.h, using ScreenCaptureKit (macOS 14+). Compiled with ARC.
//
// ScreenCaptureKit is asynchronous; each call here waits on a semaphore so the C side gets a
// plain blocking function. Completion handlers run on ScreenCaptureKit's own queues, so this
// is safe on any thread, including the main one.

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <mach/mach_time.h>

#include "cgimage.h"
#include "capture_layout.h"
#include "screen_capture.h"
#include <math.h>

static const int64_t kTimeoutNs = 5 * (int64_t)NSEC_PER_SEC;

static BOOL wait_done(dispatch_semaphore_t done) {
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kTimeoutNs)) == 0;
}

static mg_rect from_cg(CGRect r) { return (mg_rect){ r.origin.x, r.origin.y, r.size.width, r.size.height }; }
static CGRect to_cg(mg_rect r) { return CGRectMake(r.x, r.y, r.w, r.h); }

/* Copies a string, truncating on a UTF-8 character boundary. */
static void copy_utf8(char *dst, size_t cap, NSString *s) {
    const char *src = s.UTF8String ? s.UTF8String : "";
    size_t n = strlen(src);
    if (n >= cap) {
        n = cap - 1;
        while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80) n--;
    }
    memcpy(dst, src, n);
    dst[n] = '\0';
}

int mg_capture_permission(void) { return CGPreflightScreenCaptureAccess() ? 1 : 0; }
int mg_capture_request_permission(void) { return CGRequestScreenCaptureAccess() ? 1 : 0; }

/* Fetched fresh on every call, so windows opened or moved since the last step are seen.
   If this shows up in the observe-phase timings, cache it per step. */
static SCShareableContent *shareable_content(BOOL on_screen_only, char *err, size_t err_len) {
    // Checked first so a missing permission is an error here, not a system prompt mid-task.
    if (!CGPreflightScreenCaptureAccess()) {
        mg_set_err(err, err_len, @"no Screen Recording permission");
        return nil;
    }
    __block SCShareableContent *content = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:on_screen_only
                                                 completionHandler:^(SCShareableContent *c, NSError *e) {
        content = c;
        error = e;
        dispatch_semaphore_signal(done);
    }];
    if (!wait_done(done)) {
        mg_set_err(err, err_len, @"timed out listing shareable content");
        return nil;
    }
    if (!content) {
        mg_set_ns_err(err, err_len, @"couldn't list shareable content", error);
        return nil;
    }
    return content;
}

static double native_scale(CGDirectDisplayID display) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) return 1;
    double scale = (double)CGDisplayModeGetPixelWidth(mode) / (double)CGDisplayModeGetWidth(mode);
    CGDisplayModeRelease(mode);
    return scale > 0 ? scale : 1;
}

/* Window id -> position front to back. The window server's on-screen list is front to back. */
static NSDictionary<NSNumber *, NSNumber *> *stacking_order(void) {
    NSArray *info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    NSMutableDictionary<NSNumber *, NSNumber *> *z = [NSMutableDictionary dictionaryWithCapacity:info.count];
    for (NSUInteger i = 0; i < info.count; i++) {
        NSNumber *number = info[i][(__bridge NSString *)kCGWindowNumber];
        if (number) z[number] = @(i);
    }
    return z;
}

static int by_z(const void *a, const void *b) {
    int za = ((const mg_window *)a)->z, zb = ((const mg_window *)b)->z;
    if (za < 0) za = INT_MAX;
    if (zb < 0) zb = INT_MAX;
    return (za > zb) - (za < zb);
}

static SCDisplay *find_display(SCShareableContent *content, CGDirectDisplayID id) {
    if (id == 0) id = CGMainDisplayID();
    for (SCDisplay *d in content.displays)
        if (d.displayID == id) return d;
    return nil;
}

static NSArray<SCRunningApplication *> *excluded_apps(SCShareableContent *content, const mg_capture_options *opts) {
    NSMutableArray<SCRunningApplication *> *apps = [NSMutableArray array];
    if (!opts || !opts->exclude_pids) return apps;
    for (SCRunningApplication *app in content.applications) {
        for (size_t i = 0; i < opts->exclude_pid_count; i++) {
            if (app.processID == opts->exclude_pids[i]) {
                [apps addObject:app];
                break;
            }
        }
    }
    return apps;
}

/* Draws the captured image into a BGRA8 sRGB buffer the caller owns. */
static int to_buffer(CGImageRef image, mg_rect frame, mg_capture *out, char *err, size_t err_len) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (w > SIZE_MAX / 4 || !mg_bgra_layout_valid(w, h, w * 4)) {
        mg_set_err(err, err_len, @"invalid capture dimensions");
        return -1;
    }
    size_t bpr = w * 4;
    uint8_t *pixels = malloc(bpr * h);
    if (!pixels) {
        mg_set_err(err, err_len, @"out of memory");
        return -1;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!space) {
        free(pixels);
        mg_set_err(err, err_len, @"couldn't create color space");
        return -1;
    }
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, bpr, space,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!ctx) {
        free(pixels);
        mg_set_err(err, err_len, @"couldn't create bitmap context");
        return -1;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), image);
    CGContextRelease(ctx);
    *out = (mg_capture){ .pixels = pixels, .width = w, .height = h, .bytes_per_row = bpr, .frame = frame };
    return 0;
}

/* `source` is in the filter's own point space (display-local); CGRectNull means everything. */
static int capture(SCContentFilter *filter, CGRect source, CGSize points, double scale, BOOL single_window,
                   const mg_capture_options *opts, mg_rect frame, mg_capture *out, char *err, size_t err_len) {
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    size_t width, height;
    if (!mg_capture_dimensions(points.width, points.height, scale, &width, &height)) {
        mg_set_err(err, err_len, @"invalid capture dimensions");
        return -1;
    }
    config.width = width;
    config.height = height;
    if (!CGRectIsNull(source)) config.sourceRect = source;
    config.showsCursor = opts && opts->show_cursor; // defaults to YES otherwise
    config.colorSpaceName = kCGColorSpaceSRGB;
    if (single_window) config.ignoreShadowsSingleWindow = YES; // so pixels line up with the window frame

    // ARC owns the result through the shared block storage, including late completions
    // after a timeout. No caller buffer is referenced by the completion handler.
    __block id image = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [SCScreenshotManager captureImageWithFilter:filter configuration:config
                              completionHandler:^(CGImageRef img, NSError *e) {
        image = (__bridge id)img;
        error = e;
        dispatch_semaphore_signal(done);
    }];
    if (!wait_done(done)) {
        mg_set_err(err, err_len, @"timed out capturing the screen");
        return -1;
    }
    if (!image) {
        mg_set_ns_err(err, err_len, @"capture failed", error);
        return -1;
    }
    return to_buffer((__bridge CGImageRef)image, frame, out, err, err_len);
}

int mg_list_displays(mg_display **out, size_t *count, char *err, size_t err_len) {
    if (!out || !count) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        SCShareableContent *content = shareable_content(YES, err, err_len);
        if (!content) return -1;
        NSArray<SCDisplay *> *displays = content.displays;
        mg_display *list = calloc(displays.count ? displays.count : 1, sizeof *list);
        if (!list) {
            mg_set_err(err, err_len, @"out of memory");
            return -1;
        }
        CGDirectDisplayID main = CGMainDisplayID();
        for (NSUInteger i = 0; i < displays.count; i++) {
            SCDisplay *d = displays[i];
            list[i] = (mg_display){ .id = d.displayID, .frame = from_cg(d.frame),
                                    .scale = native_scale(d.displayID), .is_main = d.displayID == main };
        }
        *out = list;
        *count = displays.count;
        return 0;
    }
}

int mg_list_windows(mg_window **out, size_t *count, int on_screen_only, char *err, size_t err_len) {
    if (!out || !count) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        SCShareableContent *content = shareable_content(on_screen_only != 0, err, err_len);
        if (!content) return -1;
        NSArray<SCWindow *> *windows = content.windows;
        mg_window *list = calloc(windows.count ? windows.count : 1, sizeof *list);
        if (!list) {
            mg_set_err(err, err_len, @"out of memory");
            return -1;
        }
        NSDictionary<NSNumber *, NSNumber *> *z = stacking_order();
        for (NSUInteger i = 0; i < windows.count; i++) {
            SCWindow *w = windows[i];
            SCRunningApplication *app = w.owningApplication;
            mg_window *m = &list[i];
            m->id = w.windowID;
            m->pid = app ? app.processID : -1;
            m->layer = (int)w.windowLayer;
            m->on_screen = w.onScreen;
            NSNumber *index = z[@(w.windowID)];
            m->z = index ? index.intValue : -1;
            m->frame = from_cg(w.frame);
            copy_utf8(m->app_name, sizeof m->app_name, app.applicationName);
            copy_utf8(m->bundle_id, sizeof m->bundle_id, app.bundleIdentifier);
            copy_utf8(m->title, sizeof m->title, w.title);
        }
        // ScreenCaptureKit doesn't document its window order; sort by the window server's.
        qsort(list, windows.count, sizeof *list, by_z);
        *out = list;
        *count = windows.count;
        return 0;
    }
}

int mg_frontmost_window(mg_window *out, char *err, size_t err_len) {
    if (!out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    mg_window *windows = NULL;
    size_t count = 0;
    if (mg_list_windows(&windows, &count, 1, err, err_len) != 0) return -1;
    int rc = -1;
    for (size_t i = 0; i < count; i++) {
        if (windows[i].layer == 0 && windows[i].z >= 0) {
            *out = windows[i];
            rc = 0;
            break;
        }
    }
    free(windows);
    if (rc != 0) mg_set_err(err, err_len, @"no normal window on screen");
    return rc;
}

static void mix(uint64_t *h, int64_t v) {
    for (int i = 0; i < 8; i++) {
        *h ^= (uint64_t)(v >> (i * 8)) & 0xff;
        *h *= 1099511628211ULL; // FNV-1a
    }
}

uint64_t mg_display_config_hash(void) {
    CGDirectDisplayID ids[32];
    uint32_t n = 0;
    if (CGGetActiveDisplayList(32, ids, &n) != kCGErrorSuccess) return 0;
    uint64_t h = 1469598103934665603ULL;
    mix(&h, n);
    mix(&h, CGMainDisplayID());
    for (uint32_t i = 0; i < n; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        mix(&h, ids[i]);
        mix(&h, llround(b.origin.x));
        mix(&h, llround(b.origin.y));
        mix(&h, llround(b.size.width));
        mix(&h, llround(b.size.height));
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ids[i]);
        if (mode) {
            mix(&h, (int64_t)CGDisplayModeGetPixelWidth(mode));
            mix(&h, (int64_t)CGDisplayModeGetPixelHeight(mode));
            CGDisplayModeRelease(mode);
        }
    }
    return h;
}

int mg_capture_display(uint32_t display_id, const mg_capture_options *opts, mg_capture *out,
                       char *err, size_t err_len) {
    if (!out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        SCShareableContent *content = shareable_content(YES, err, err_len);
        if (!content) return -1;
        SCDisplay *display = find_display(content, display_id);
        if (!display) {
            mg_set_err(err, err_len, [NSString stringWithFormat:@"no display with id %u", display_id]);
            return -1;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                     excludingApplications:excluded_apps(content, opts)
                                                          exceptingWindows:@[]];
        double scale = opts && opts->scale > 0 ? opts->scale : native_scale(display.displayID);
        return capture(filter, CGRectNull, display.frame.size, scale, NO, opts, from_cg(display.frame),
                       out, err, err_len);
    }
}

int mg_capture_rect(mg_rect rect, const mg_capture_options *opts, mg_capture *out, char *err, size_t err_len) {
    if (!out || !isfinite(rect.x) || !isfinite(rect.y) ||
        !isfinite(rect.w) || !isfinite(rect.h) || rect.w <= 0 || rect.h <= 0) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        SCShareableContent *content = shareable_content(YES, err, err_len);
        if (!content) return -1;
        CGRect want = to_cg(rect);
        CGPoint center = CGPointMake(CGRectGetMidX(want), CGRectGetMidY(want));
        SCDisplay *display = nil;
        for (SCDisplay *d in content.displays)
            if (CGRectContainsPoint(d.frame, center)) display = d;
        if (!display) {
            mg_set_err(err, err_len, @"rect's center isn't on any display");
            return -1;
        }
        CGRect clipped = CGRectIntersection(want, display.frame);
        CGRect local = CGRectOffset(clipped, -display.frame.origin.x, -display.frame.origin.y);
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                     excludingApplications:excluded_apps(content, opts)
                                                          exceptingWindows:@[]];
        double scale = opts && opts->scale > 0 ? opts->scale : native_scale(display.displayID);
        return capture(filter, local, clipped.size, scale, NO, opts, from_cg(clipped), out, err, err_len);
    }
}

int mg_capture_window(uint32_t window_id, const mg_capture_options *opts, mg_capture *out,
                      char *err, size_t err_len) {
    if (!out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        SCShareableContent *content = shareable_content(NO, err, err_len);
        if (!content) return -1;
        SCWindow *window = nil;
        for (SCWindow *w in content.windows)
            if (w.windowID == window_id) window = w;
        if (!window) {
            mg_set_err(err, err_len, [NSString stringWithFormat:@"no window with id %u", window_id]);
            return -1;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
        double scale = opts && opts->scale > 0 ? opts->scale : filter.pointPixelScale;
        return capture(filter, CGRectNull, filter.contentRect.size, scale, YES, opts, from_cg(window.frame),
                       out, err, err_len);
    }
}

void mg_capture_free(mg_capture *capture) {
    if (!capture) return;
    free(capture->pixels);
    capture->pixels = NULL;
}

// MARK: - Streaming

static double mach_to_seconds(uint64_t t) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return (double)t * tb.numer / tb.denom / 1e9;
}

double mg_clock_now(void) { return mach_to_seconds(mach_absolute_time()); }

/* Receives frames on ScreenCaptureKit's queue and keeps only the newest. */
@interface MGStream : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic) mg_rect frame;
@end

@implementation MGStream {
    NSCondition *_cond;
    CVPixelBufferRef _latest; // retained; guarded by _cond
    double _latestTime;
    NSString *_stopReason;   // set if the system stopped the stream
}

- (instancetype)init {
    if ((self = [super init])) _cond = [[NSCondition alloc] init];
    return self;
}

- (void)dealloc {
    if (_latest) CVPixelBufferRelease(_latest);
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)buffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, false);
    if (!attachments || CFArrayGetCount(attachments) == 0) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
    // Idle/blank/suspended frames carry no new image.
    if ([info[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(buffer);
    if (!pixels) return;
    NSNumber *shown = info[SCStreamFrameInfoDisplayTime]; // mach absolute time
    double t = shown ? mach_to_seconds(shown.unsignedLongLongValue) : mg_clock_now();

    CVPixelBufferRetain(pixels);
    [_cond lock];
    CVPixelBufferRef old = _latest;
    _latest = pixels;
    _latestTime = t;
    [_cond broadcast];
    [_cond unlock];
    if (old) CVPixelBufferRelease(old);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    [_cond lock];
    _stopReason = error.localizedDescription ? error.localizedDescription : @"stream stopped";
    [_cond broadcast];
    [_cond unlock];
}

/* 0 = copied a frame shown at or after `after`; 1 = none within the timeout; -1 = error. */
- (int)copyAfter:(double)after timeout:(double)timeout out:(mg_capture *)out time:(double *)frameTime
             err:(char *)err len:(size_t)errLen {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout > 0 ? timeout : 0];
    [_cond lock];
    while (!_stopReason && !(_latest && _latestTime >= after)) {
        if (![_cond waitUntilDate:deadline]) break;
    }
    if (_stopReason) {
        NSString *reason = _stopReason;
        [_cond unlock];
        mg_set_err(err, errLen, [NSString stringWithFormat:@"stream stopped: %@", reason]);
        return -1;
    }
    if (!(_latest && _latestTime >= after)) {
        [_cond unlock];
        return 1;
    }
    // Copy outside the lock so new frames aren't held up; the retain keeps this one alive.
    CVPixelBufferRef pixels = CVPixelBufferRetain(_latest);
    double t = _latestTime;
    [_cond unlock];

    int rc = -1;
    if (CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_32BGRA) {
        mg_set_err(err, errLen, @"unexpected stream pixel format");
    } else if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        size_t w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels);
        size_t src_bpr = CVPixelBufferGetBytesPerRow(pixels);
        const uint8_t *src = CVPixelBufferGetBaseAddress(pixels);
        bool valid = src && mg_bgra_layout_valid(w, h, src_bpr);
        size_t bpr = valid ? w * 4 : 0;
        uint8_t *dst = valid ? malloc(bpr * h) : NULL;
        if (dst) {
            for (size_t y = 0; y < h; y++) memcpy(dst + y * bpr, src + y * src_bpr, bpr);
            *out = (mg_capture){ .pixels = dst, .width = w, .height = h, .bytes_per_row = bpr, .frame = self.frame };
            if (frameTime) *frameTime = t;
            rc = 0;
        } else {
            mg_set_err(err, errLen, @"couldn't copy frame");
        }
        CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    } else {
        mg_set_err(err, errLen, @"couldn't lock frame");
    }
    CVPixelBufferRelease(pixels);
    return rc;
}
@end

int mg_stream_start(uint32_t display_id, const mg_capture_options *opts, double max_fps,
                    mg_stream **out, char *err, size_t err_len) {
    if (!out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        SCShareableContent *content = shareable_content(YES, err, err_len);
        if (!content) return -1;
        SCDisplay *display = find_display(content, display_id);
        if (!display) {
            mg_set_err(err, err_len, [NSString stringWithFormat:@"no display with id %u", display_id]);
            return -1;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                     excludingApplications:excluded_apps(content, opts)
                                                          exceptingWindows:@[]];
        double scale = opts && opts->scale > 0 ? opts->scale : native_scale(display.displayID);
        size_t width, height;
        if (!mg_capture_dimensions(display.frame.size.width, display.frame.size.height, scale, &width, &height)) {
            mg_set_err(err, err_len, @"invalid capture dimensions");
            return -1;
        }
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = width;
        config.height = height;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.colorSpaceName = kCGColorSpaceSRGB;
        config.showsCursor = opts && opts->show_cursor;
        config.minimumFrameInterval = CMTimeMakeWithSeconds(1.0 / (max_fps > 0 ? max_fps : 30), 600);

        MGStream *s = [[MGStream alloc] init];
        s.frame = from_cg(display.frame);
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:s];
        dispatch_queue_t queue = dispatch_queue_create("magent.capture.stream", DISPATCH_QUEUE_SERIAL);
        NSError *error = nil;
        if (![stream addStreamOutput:s type:SCStreamOutputTypeScreen sampleHandlerQueue:queue error:&error]) {
            mg_set_ns_err(err, err_len, @"couldn't add stream output", error);
            return -1;
        }
        __block NSError *startError = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [stream startCaptureWithCompletionHandler:^(NSError *e) {
            startError = e;
            dispatch_semaphore_signal(done);
        }];
        if (!wait_done(done)) {
            [stream stopCaptureWithCompletionHandler:nil];
            mg_set_err(err, err_len, @"timed out starting the stream");
            return -1;
        }
        if (startError) {
            mg_set_ns_err(err, err_len, @"couldn't start the stream", startError);
            return -1;
        }
        s.stream = stream;
        *out = (__bridge_retained void *)s;
        return 0;
    }
}

int mg_stream_latest(mg_stream *stream, mg_capture *out, double *frame_time, char *err, size_t err_len) {
    return mg_stream_wait_after(stream, -INFINITY, 0, out, frame_time, err, err_len);
}

int mg_stream_wait_after(mg_stream *stream, double after, double timeout_s, mg_capture *out,
                         double *frame_time, char *err, size_t err_len) {
    if (!stream || !out) {
        mg_set_err(err, err_len, @"invalid argument");
        return -1;
    }
    @autoreleasepool {
        MGStream *s = (__bridge MGStream *)(void *)stream;
        return [s copyAfter:after timeout:timeout_s out:out time:frame_time err:err len:err_len];
    }
}

void mg_stream_stop(mg_stream *stream) {
    if (!stream) return;
    @autoreleasepool {
        MGStream *s = CFBridgingRelease((CFTypeRef)stream);
        SCStream *sc = s.stream;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [sc stopCaptureWithCompletionHandler:^(NSError *e) {
            (void)e;
            dispatch_semaphore_signal(done);
        }];
        wait_done(done);
        [sc removeStreamOutput:s type:SCStreamOutputTypeScreen error:nil];
        s.stream = nil; // SCStream holds its output; breaking the link lets both be freed
    }
}
