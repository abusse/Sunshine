#ifndef SUNSHINE_PLATFORM_AV_AUDIO_H
#define SUNSHINE_PLATFORM_AV_AUDIO_H

#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>

#include "sunshine/platform/macos/TPCircularBuffer/TPCircularBuffer.h"

#define kBufferLength 4096

@interface AVAudio : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate> {
  @public TPCircularBuffer audioSampleBuffer;
}

@property (nonatomic, assign) NSString *sourceName;
@property (nonatomic, assign) AVCaptureSession *audioCaptureSession;
@property (nonatomic, assign) AVCaptureConnection *audioConnection;
@property (nonatomic, assign) NSCondition *samplesArrivedSignal;

+ (NSArray *)microphoneNames;

- (int)setupMicrophoneWithName:(NSString *)name sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;

@end

#endif //SUNSHINE_PLATFORM_AV_AUDIO_H
