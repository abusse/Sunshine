#ifndef SUNSHINE_PLATFORM_AV_VIDEO_H
#define SUNSHINE_PLATFORM_AV_VIDEO_H

#import <AVFoundation/AVFoundation.h>


struct CaptureSession {
  AVCaptureVideoDataOutput *output;
  NSCondition *captureStopped;
};

@interface AVVideo : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

#define kMaxDisplays 32

@property(nonatomic, assign) CGDirectDisplayID displayID;
@property(nonatomic, assign) CMTime minFrameDuration;
@property(nonatomic, assign) OSType pixelFormat;
@property(nonatomic, assign) int frameWidth;
@property(nonatomic, assign) int frameHeight;
@property(nonatomic, assign) int paddingLeft;
@property(nonatomic, assign) int paddingRight;
@property(nonatomic, assign) int paddingTop;
@property(nonatomic, assign) int paddingBottom;

typedef bool (^FrameCallbackBlock)(CMSampleBufferRef);

@property(nonatomic, assign) AVCaptureSession *session;
@property(nonatomic, assign) NSMapTable<AVCaptureConnection *, AVCaptureVideoDataOutput *> *videoOutputs;
@property(nonatomic, assign) NSMapTable<AVCaptureConnection *, FrameCallbackBlock> *captureCallbacks;
@property(nonatomic, assign) NSMapTable<AVCaptureConnection *, NSCondition *> *captureSignals;

+ (NSArray<NSDictionary *> *)displayNames;

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;
- (NSCondition *)capture:(FrameCallbackBlock)frameCallback;

@end

#endif //SUNSHINE_PLATFORM_AV_VIDEO_H
