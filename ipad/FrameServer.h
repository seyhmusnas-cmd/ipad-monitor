// A small TCP server that receives frames from the Mac over USB (through usbmuxd).
//
// Protocol (Mac -> iPad):  [4-byte length, big-endian][1-byte type][payload]
//   type 1 = JPEG frame
//   type 2 = H.264 frame: [flags: 1 = key frame][key frames only: 2-byte SPS length, SPS,
//            2-byte PPS length, PPS][NAL units in AVCC format]
// Protocol (iPad -> Mac):  [1-byte type][payload]
//   0x01 ack, 0x02 ack + "please send a key frame" (no payload)
//   0x10 tap          [x u16][y u16]
//   0x11 right click  [x u16][y u16]
//   0x12 drag         [phase: 0 begin, 1 move, 2 end][x u16][y u16]
//   0x13 scroll       [x u16][y u16][dx i16][dy i16]
// x/y are 0..65535 within the picture (top left is 0,0); dx/dy are 1/32768ths of the picture size.
// All big-endian. The Mac only sends the next frame after an ack, so latency never builds up.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

@class FrameServer;

@protocol FrameServerDelegate <NSObject>
// All called on the main thread. The delegate must call frameDisplayed... after every frame.
- (void)frameServer:(FrameServer *)server didReceiveImage:(CGImageRef)image;
- (void)frameServer:(FrameServer *)server didReceiveVideoSample:(CMSampleBufferRef)sample;
- (void)frameServer:(FrameServer *)server connectionChanged:(BOOL)connected;
@end

@interface FrameServer : NSObject

@property (nonatomic, weak) id<FrameServerDelegate> delegate;

- (instancetype)initWithPort:(uint16_t)port;
- (void)start;

// Called by the delegate once a frame is on screen; sends the ack to the Mac.
// needKeyFrame: the decoder got stuck, ask the Mac for a fresh key frame.
- (void)frameDisplayedNeedingKeyFrame:(BOOL)needKeyFrame;

// Sends a touch message (silently dropped when not connected). Safe to call from any thread.
- (void)sendMessage:(const uint8_t *)bytes length:(size_t)length;

@end
