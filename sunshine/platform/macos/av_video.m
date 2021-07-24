#import "av_video.h"

@implementation AVVideo

- (void)dealloc {
  self.videoConnection = nil;
  @synchronized(self) {
    CGContextRelease(self.currentFrame);
  }
  [self.session release];
  [super dealloc];
}

- (BOOL)setupVideo:(int)width height:(int)height frameRate:(int)frameRate {
  self.currentFrame = nil;
  self.session      = [[AVCaptureSession alloc] init];

  AVCaptureScreenInput *screenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:CGMainDisplayID()];
  [screenInput setMinFrameDuration:CMTimeMake(1, frameRate)];

  if([self.session canAddInput:screenInput]) {
    [self.session addInput:screenInput];
  }
  else {
    [screenInput release];
    return false;
  }

  AVCaptureVideoDataOutput *movieOutput = [[AVCaptureVideoDataOutput alloc] init];

  if(height > 0 && width > 0) {
    [movieOutput setVideoSettings:@{
      (NSString *)kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA],
      (NSString *)kCVPixelBufferWidthKey: [NSNumber numberWithInt:width],
      (NSString *)kCVPixelBufferHeightKey: [NSNumber numberWithInt:height]
    }];
  }
  else {
    [movieOutput setVideoSettings:@{
      (NSString *)kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA]
    }];
  }

  dispatch_queue_attr_t qos       = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
  dispatch_queue_t recordingQueue = dispatch_queue_create("videoCaptureQueue", qos);

  [movieOutput setSampleBufferDelegate:self queue:recordingQueue];

  if([self.session canAddOutput:movieOutput]) {
    [self.session addOutput:movieOutput];
  }
  else {
    [screenInput release];
    [movieOutput release];
    return false;
  }

  self.videoConnection = [movieOutput connectionWithMediaType:AVMediaTypeVideo];

  [self.session startRunning];

  [screenInput release];
  [movieOutput release];

  return true;
}

- (CGImageRef)getSnapshot:(CMTime)timeout showCursor:(bool)showCursor {
  CGImageRef result = NULL;

  while(result == NULL) {
    @synchronized(self) {
      if(self.currentFrame != NULL) {
        result = CGBitmapContextCreateImage(self.currentFrame);
      }
    }
  }

  // this has to be released by the caller
  return result;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  if(connection == self.videoConnection) {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    void *baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t width   = CVPixelBufferGetWidth(pixelBuffer);
    size_t height  = CVPixelBufferGetHeight(pixelBuffer);

    CGContextRef cgContext = CGBitmapContextCreate(baseAddr, width, height, 8, CVPixelBufferGetBytesPerRow(pixelBuffer), CGColorSpaceCreateDeviceRGB(), kCGImageAlphaNoneSkipLast);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    if(cgContext != NULL) {
      @synchronized(self) {
        CGContextRelease(self.currentFrame);
        self.currentFrame = cgContext;
      }
    }
  }
}

@end
