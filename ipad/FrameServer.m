#import "FrameServer.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

// Sanity limit: a 1024x768 frame is far below this.
static const uint32_t kMaxFrameBytes = 8 * 1024 * 1024;

enum { kTypeJPEG = 1, kTypeH264 = 2 };

@implementation FrameServer {
    uint16_t _port;
    int _client;  // active connection, or -1
    CMVideoFormatDescriptionRef _format;  // SPS/PPS from the last key frame; reader thread only
}

- (instancetype)initWithPort:(uint16_t)port {
    if ((self = [super init])) {
        _port = port;
        _client = -1;
    }
    return self;
}

- (void)start {
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(acceptLoop) object:nil];
    t.name = @"FrameServer";
    [t start];
}

#pragma mark - Networking

static BOOL readFully(int fd, void *buf, size_t len) {
    uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n <= 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

- (int)openListener {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    int yes = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);

    // Only reachable from inside the device (the usbmuxd tunnel), not over Wi-Fi.
    struct sockaddr_in addr = {0};
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(listener, 1) != 0) {
        NSLog(@"FrameServer: couldn't open port %u (%d)", _port, errno);
        close(listener);
        return -1;
    }
    NSLog(@"FrameServer: listening on port %u", _port);
    return listener;
}

- (void)acceptLoop {
    int yes = 1;
    for (;;) {
        // iOS can mark the listening socket "defunct" while the app is suspended; accept()
        // then fails forever. When that happens, close the socket and open a new one.
        int listener = [self openListener];
        if (listener < 0) {
            sleep(1);
            continue;
        }
        for (;;) {
            int fd = accept(listener, NULL, NULL);
            if (fd < 0) {
                if (errno == EINTR) continue;
                NSLog(@"FrameServer: accept failed (%d), reopening the socket", errno);
                break;
            }
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes);
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);

            @synchronized (self) { _client = fd; }
            [self notifyConnected:YES];
            [self readFramesFrom:fd];
            @synchronized (self) { _client = -1; }
            close(fd);
            [self notifyConnected:NO];
        }
        close(listener);
        sleep(1);
    }
}

- (void)readFramesFrom:(int)fd {
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    for (;;) {
        @autoreleasepool {
            uint32_t be;
            if (!readFully(fd, &be, 4)) break;
            uint32_t len = ntohl(be);
            if (len < 2 || len > kMaxFrameBytes) break;

            uint8_t type;
            if (!readFully(fd, &type, 1)) break;
            NSMutableData *payload = [NSMutableData dataWithLength:len - 1];
            if (!readFully(fd, payload.mutableBytes, len - 1)) break;

            if (type == kTypeJPEG) {
                CGImageRef image = [self decodeJPEG:payload colorSpace:rgb];
                if (!image) {
                    [self frameDisplayedNeedingKeyFrame:NO];  // skip a broken frame, keep the stream going
                    continue;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate frameServer:self didReceiveImage:image];
                    CGImageRelease(image);
                });
            } else if (type == kTypeH264) {
                CMSampleBufferRef sample = [self sampleFromH264:payload];
                if (!sample) {
                    [self frameDisplayedNeedingKeyFrame:YES];
                    continue;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate frameServer:self didReceiveVideoSample:sample];
                    CFRelease(sample);
                });
            } else {
                [self frameDisplayedNeedingKeyFrame:NO];
            }
        }
    }
    CGColorSpaceRelease(rgb);
    if (_format) {
        CFRelease(_format);
        _format = NULL;
    }
}

// Turns an H.264 frame into a CMSampleBuffer for the hardware decoder (AVSampleBufferDisplayLayer).
// The format description is built from the SPS/PPS that come with each key frame.
- (CMSampleBufferRef)sampleFromH264:(NSData *)payload CF_RETURNS_RETAINED {
    const uint8_t *p = payload.bytes;
    size_t len = payload.length, off = 1;
    if (len < 1) return NULL;

    if (p[0] & 1) {
        const uint8_t *sets[2];
        size_t sizes[2];
        for (int i = 0; i < 2; i++) {
            if (off + 2 > len) return NULL;
            sizes[i] = ((size_t)p[off] << 8) | p[off + 1];
            off += 2;
            if (off + sizes[i] > len) return NULL;
            sets[i] = p + off;
            off += sizes[i];
        }
        CMVideoFormatDescriptionRef format = NULL;
        OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, 2, sets, sizes, 4, &format);
        if (st != noErr) {
            NSLog(@"FrameServer: couldn't read SPS/PPS (%d)", (int)st);
            return NULL;
        }
        if (_format) CFRelease(_format);
        _format = format;
    }
    if (!_format || off >= len) return NULL;  // can't decode a delta frame before a key frame

    size_t size = len - off;
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, size, kCFAllocatorDefault, NULL,
                                           0, size, kCMBlockBufferAssureMemoryNowFlag, &block) != noErr) {
        return NULL;
    }
    CMBlockBufferReplaceDataBytes(p + off, block, 0, size);

    CMSampleBufferRef sample = NULL;
    OSStatus st = CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL, _format,
                                       1, 0, NULL, 1, &size, &sample);
    CFRelease(block);
    if (st != noErr) return NULL;

    // No timing: show each frame as soon as it arrives.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    return sample;
}

// Fully decode the JPEG into a bitmap off the main thread; otherwise Core Animation
// decodes it on the main thread and the UI stutters.
- (CGImageRef)decodeJPEG:(NSData *)data colorSpace:(CGColorSpaceRef)rgb CF_RETURNS_RETAINED {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef jpeg = CGImageCreateWithJPEGDataProvider(provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!jpeg) return NULL;

    size_t w = CGImageGetWidth(jpeg), h = CGImageGetHeight(jpeg);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, rgb,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), jpeg);
    CGImageRef decoded = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGImageRelease(jpeg);
    return decoded;
}

- (void)frameDisplayedNeedingKeyFrame:(BOOL)needKeyFrame {
    uint8_t ack = needKeyFrame ? 2 : 1;
    [self sendMessage:&ack length:1];
}

- (void)sendMessage:(const uint8_t *)bytes length:(size_t)length {
    // Acks and touches can come from different threads; lock so messages never interleave.
    @synchronized (self) {
        if (_client < 0) return;
        write(_client, bytes, length);
    }
}

- (void)notifyConnected:(BOOL)connected {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate frameServer:self connectionChanged:connected];
    });
}

@end
