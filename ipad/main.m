// Shows a Mac display on an old iPad (tested: iPad mini 1st gen, iOS 9.3, armv7).
// MonitorHost on the Mac streams the screen over USB as H.264 (or JPEG) frames.
// H.264 is decoded by the A5's hardware decoder through AVSampleBufferDisplayLayer.
//
// Touch: one-finger tap = click, one-finger drag = click-and-drag,
// two-finger pan = scroll, two-finger tap = right click.

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "FrameServer.h"

static const uint16_t kPort = 2345;

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@interface ScreenViewController : UIViewController <FrameServerDelegate>
@end

@implementation ScreenViewController {
    FrameServer *_server;
    CALayer *_screen;                     // JPEG frames
    AVSampleBufferDisplayLayer *_video;   // H.264 frames (hardware decoder)
    UILabel *_status;
    UILabel *_fps;
    NSUInteger _frames;
    CFTimeInterval _fpsSince;
    CGSize _contentSize;  // pixel size of the picture being shown; used to map touches
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _screen = [CALayer layer];
    _screen.contentsGravity = kCAGravityResizeAspect;
    _screen.magnificationFilter = kCAFilterLinear;
    // Turn off Core Animation's implicit transitions when frames change.
    _screen.actions = @{ @"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null], @"hidden": [NSNull null] };
    [self.view.layer addSublayer:_screen];

    _video = [[AVSampleBufferDisplayLayer alloc] init];
    _video.videoGravity = AVLayerVideoGravityResizeAspect;
    _video.actions = _screen.actions;
    [self.view.layer addSublayer:_video];

    _status = [[UILabel alloc] init];
    _status.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    _status.font = [UIFont systemFontOfSize:22];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    [self.view addSubview:_status];

    // Small frames-per-second counter in the top right corner.
    _fps = [[UILabel alloc] init];
    _fps.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.4 alpha:0.8];
    _fps.font = [UIFont fontWithName:@"Menlo" size:12];
    _fps.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:_fps];

    [self showWaiting];
    [self setUpGestures];

    _server = [[FrameServer alloc] initWithPort:kPort];
    _server.delegate = self;
    [_server start];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _screen.frame = b;
    _video.frame = b;
    _status.frame = CGRectInset(b, 40, 0);
    _fps.frame = CGRectMake(b.size.width - 110, 4, 104, 16);
}

- (void)showWaiting {
    _contentSize = CGSizeZero;
    _screen.contents = nil;
    [_video flushAndRemoveImage];
    _fps.text = nil;
    UIDevice *d = [UIDevice currentDevice];
    _status.text = [NSString stringWithFormat:@"Waiting for the Mac…\n\nConnect USB and start MonitorHost.\n\n%@ · iOS %@ · port %u",
                    d.name, d.systemVersion, kPort];
    _status.hidden = NO;
}

#pragma mark - FrameServerDelegate

- (void)frameServer:(FrameServer *)server didReceiveImage:(CGImageRef)image {
    _status.hidden = YES;
    _video.hidden = YES;
    _screen.hidden = NO;
    _screen.contents = (__bridge id)image;
    _contentSize = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
    [server frameDisplayedNeedingKeyFrame:NO];
    [self countFrame];
}

- (void)frameServer:(FrameServer *)server didReceiveVideoSample:(CMSampleBufferRef)sample {
    _status.hidden = YES;
    _screen.hidden = YES;
    _video.hidden = NO;

    // If the decoder has failed, reset it and ask the Mac for a clean key frame.
    BOOL needKey = NO;
    if (_video.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"Video layer failed: %@", _video.error);
        [_video flush];
        needKey = YES;
    }
    [_video enqueueSampleBuffer:sample];
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(CMSampleBufferGetFormatDescription(sample));
    _contentSize = CGSizeMake(dims.width, dims.height);
    [server frameDisplayedNeedingKeyFrame:needKey];
    [self countFrame];
}

- (void)countFrame {
    _frames++;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _fpsSince >= 1.0) {
        _fps.text = [NSString stringWithFormat:@"%.0f fps", _frames / (now - _fpsSince)];
        _frames = 0;
        _fpsSince = now;
    }
}

- (void)frameServer:(FrameServer *)server connectionChanged:(BOOL)connected {
    if (connected) {
        _status.text = @"Connected, waiting for the picture…";
        _frames = 0;
        _fpsSince = CACurrentMediaTime();
    } else {
        [self showWaiting];
    }
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

#pragma mark - Touch

- (void)setUpGestures {
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    [self.view addGestureRecognizer:tap];

    UITapGestureRecognizer *rightTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rightTapped:)];
    rightTap.numberOfTouchesRequired = 2;
    [self.view addGestureRecognizer:rightTap];

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    drag.maximumNumberOfTouches = 1;
    [self.view addGestureRecognizer:drag];

    UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scrolled:)];
    scroll.minimumNumberOfTouches = 2;
    scroll.maximumNumberOfTouches = 2;
    [self.view addGestureRecognizer:scroll];
}

// The area the picture covers on screen (aspect-fit, centered).
- (CGRect)contentRect {
    if (_contentSize.width <= 0) return CGRectZero;
    return AVMakeRectWithAspectRatioInsideRect(_contentSize, self.view.bounds);
}

static void putU16(uint8_t *p, int v) {
    p[0] = (uint8_t)((v >> 8) & 0xff);
    p[1] = (uint8_t)(v & 0xff);
}

// Writes the point as 0..65535 within the picture into p; NO if nothing is shown yet.
- (BOOL)writePoint:(CGPoint)pt into:(uint8_t *)p {
    CGRect r = [self contentRect];
    if (CGRectIsEmpty(r)) return NO;
    double nx = fmin(fmax((pt.x - r.origin.x) / r.size.width, 0), 1);
    double ny = fmin(fmax((pt.y - r.origin.y) / r.size.height, 0), 1);
    putU16(p, (int)lround(nx * 65535));
    putU16(p + 2, (int)lround(ny * 65535));
    return YES;
}

- (void)tapped:(UITapGestureRecognizer *)g {
    uint8_t m[5] = {0x10};
    if ([self writePoint:[g locationInView:self.view] into:m + 1]) [_server sendMessage:m length:sizeof m];
}

- (void)rightTapped:(UITapGestureRecognizer *)g {
    uint8_t m[5] = {0x11};
    if ([self writePoint:[g locationInView:self.view] into:m + 1]) [_server sendMessage:m length:sizeof m];
}

- (void)sendDrag:(uint8_t)phase at:(CGPoint)pt {
    uint8_t m[6] = {0x12, phase};
    if ([self writePoint:pt into:m + 2]) [_server sendMessage:m length:sizeof m];
}

- (void)dragged:(UIPanGestureRecognizer *)g {
    CGPoint now = [g locationInView:self.view];
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            // A pan only begins after the finger has moved ~10 pt; press where the finger first landed.
            CGPoint moved = [g translationInView:self.view];
            [self sendDrag:0 at:CGPointMake(now.x - moved.x, now.y - moved.y)];
            [self sendDrag:1 at:now];
            break;
        }
        case UIGestureRecognizerStateChanged:
            [self sendDrag:1 at:now];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self sendDrag:2 at:now];
            break;
        default:
            break;
    }
}

- (void)scrolled:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan && g.state != UIGestureRecognizerStateChanged) return;
    CGRect r = [self contentRect];
    if (CGRectIsEmpty(r)) return;
    CGPoint d = [g translationInView:self.view];
    [g setTranslation:CGPointZero inView:self.view];

    uint8_t m[9] = {0x13};
    [self writePoint:[g locationInView:self.view] into:m + 1];
    int dx = (int)lround(fmax(fmin(d.x / r.size.width, 0.99), -0.99) * 32768);
    int dy = (int)lround(fmax(fmin(d.y / r.size.height, 0.99), -0.99) * 32768);
    putU16(m + 5, dx);
    putU16(m + 7, dy);
    [_server sendMessage:m length:sizeof m];
}

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // It's a monitor now: never let the screen dim or lock.
    application.idleTimerDisabled = YES;

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ScreenViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
