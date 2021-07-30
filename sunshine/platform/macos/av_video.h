#ifndef SUNSHINE_PLATFORM_AV_VIDEO_H
#define SUNSHINE_PLATFORM_AV_VIDEO_H

#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>

@interface AVVideo : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

#define kMaxDisplays 32

@property(nonatomic, assign) CMTime minFrameDuration;
@property(nonatomic, assign) int frameWidth;
@property(nonatomic, assign) int frameHeight;
@property(atomic, assign) bool capture;

typedef bool (^frameCallbackBlock)(CGImageRef);
@property(nonatomic, copy) frameCallbackBlock frameCallback;

@property(nonatomic, assign) AVCaptureSession *session;
@property(nonatomic, assign) AVCaptureConnection *videoConnection;
@property(nonatomic, assign) NSCondition *captureStopped;

+ (NSArray<NSDictionary *> *)displayNames;

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;
- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate width:(int)width height:(int)height;

- (bool)capture:(frameCallbackBlock)frameCallback;

@end

#endif //SUNSHINE_PLATFORM_AV_VIDEO_H
