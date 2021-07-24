#ifndef SUNSHINE_PLATFORM_AV_VIDEO_H
#define SUNSHINE_PLATFORM_AV_VIDEO_H

#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>

@interface AVVideo : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

@property(nonatomic, assign) AVCaptureSession *session;
@property(nonatomic, assign) AVCaptureConnection *videoConnection;
@property(nonatomic, assign) CGContextRef currentFrame;

- (BOOL)setupVideo:(int)width height:(int)height;
- (CGImageRef)getSnapshot:(CMTime)timeout showCursor:(bool)showCursor;

@end

#endif //SUNSHINE_PLATFORM_AV_VIDEO_H
