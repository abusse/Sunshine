#import "av_video.h"

@implementation AVVideo

// XXX: Currenty, this function only returns the screen IDs as names,
// which is not very helpfull to the user. The API to retrieve names
// was deprecated with 10.9+.
// However, there is a solution with little external code that can be used:
// https://stackoverflow.com/questions/20025868/cgdisplayioserviceport-is-deprecated-in-os-x-10-9-how-to-replace
+ (NSArray<NSDictionary *> *)displayNames {
  NSMutableArray *result = [[NSMutableArray alloc] init];

  CGDirectDisplayID displays[kMaxDisplays];
  uint32_t count;
  if(CGGetActiveDisplayList(kMaxDisplays, displays, &count) != kCGErrorSuccess) {
    return result;
  }

  for(uint32_t i = 0; i < count; i++) {
    [result addObject:@{
      @"id": [NSNumber numberWithUnsignedInt:displays[i]],
      @"name": [NSString stringWithFormat:@"%d", displays[i]]
    }];
  }

  return result;
}

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];

  CGImageRef screenshot = CGDisplayCreateImage(displayID);

  self.displayID        = displayID;
  self.pixelFormat      = kCVPixelFormatType_32BGRA;
  self.frameWidth       = CGImageGetWidth(screenshot);
  self.frameHeight      = CGImageGetHeight(screenshot);
  self.paddingLeft      = 0;
  self.paddingRight     = 0;
  self.paddingTop       = 0;
  self.paddingBottom    = 0;
  self.minFrameDuration = CMTimeMake(1, frameRate);

  self.session = [[AVCaptureSession alloc] init];

  self.videoOutputs     = [[NSMapTable alloc] init];
  self.captureCallbacks = [[NSMapTable alloc] init];
  self.captureSignals   = [[NSMapTable alloc] init];

  AVCaptureScreenInput *screenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:self.displayID];
  [screenInput setMinFrameDuration:self.minFrameDuration];

  if([self.session canAddInput:screenInput]) {
    [self.session addInput:screenInput];
  }
  else {
    [screenInput release];
    return nil;
  }

  [self.session startRunning];

  return self;
}

- (void)dealloc {
  [self.session stopRunning];
  [super dealloc];
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  CGImageRef screenshot = CGDisplayCreateImage(self.displayID);

  self.frameWidth  = frameWidth;
  self.frameHeight = frameHeight;

  double screenRatio = (double)CGImageGetWidth(screenshot) / (double)CGImageGetHeight(screenshot);
  double streamRatio = (double)frameWidth / (double)frameHeight;

  if(screenRatio < streamRatio) {
    int padding        = frameWidth - (frameHeight * screenRatio);
    self.paddingLeft   = padding / 2;
    self.paddingRight  = padding - self.paddingLeft;
    self.paddingTop    = 0;
    self.paddingBottom = 0;
  }
  else {
    int padding        = frameHeight - (frameWidth / screenRatio);
    self.paddingLeft   = 0;
    self.paddingRight  = 0;
    self.paddingTop    = padding / 2;
    self.paddingBottom = padding - self.paddingTop;
  }
}

- (NSCondition *)capture:(FrameCallbackBlock)frameCallback {
  @synchronized(self) {
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];

    [videoOutput setVideoSettings:@{
      (NSString *)kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:self.pixelFormat],
      (NSString *)kCVPixelBufferWidthKey: [NSNumber numberWithInt:self.frameWidth],
      (NSString *)kCVPixelBufferExtendedPixelsRightKey: [NSNumber numberWithInt:self.paddingRight],
      (NSString *)kCVPixelBufferExtendedPixelsLeftKey: [NSNumber numberWithInt:self.paddingLeft],
      (NSString *)kCVPixelBufferExtendedPixelsTopKey: [NSNumber numberWithInt:self.paddingTop],
      (NSString *)kCVPixelBufferExtendedPixelsBottomKey: [NSNumber numberWithInt:self.paddingBottom],
      (NSString *)kCVPixelBufferHeightKey: [NSNumber numberWithInt:self.frameHeight]
    }];

    dispatch_queue_attr_t qos       = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
    dispatch_queue_t recordingQueue = dispatch_queue_create("videoCaptureQueue", qos);
    [videoOutput setSampleBufferDelegate:self queue:recordingQueue];

    [self.session stopRunning];

    if([self.session canAddOutput:videoOutput]) {
      [self.session addOutput:videoOutput];
    }
    else {
      [videoOutput release];
      return nil;
    }

    AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    NSCondition *signal                  = [[NSCondition alloc] init];

    [self.videoOutputs setObject:videoOutput forKey:videoConnection];
    [self.captureCallbacks setObject:frameCallback forKey:videoConnection];
    [self.captureSignals setObject:signal forKey:videoConnection];

    [self.session startRunning];

    return signal;
  }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {

  FrameCallbackBlock callback = [self.captureCallbacks objectForKey:connection];

  if(callback != nil) {
    if(!callback(sampleBuffer)) {
      @synchronized(self) {
        [self.session stopRunning];
        [self.captureCallbacks removeObjectForKey:connection];
        [self.session removeOutput:[self.videoOutputs objectForKey:connection]];
        [self.videoOutputs removeObjectForKey:connection];
        [[self.captureSignals objectForKey:connection] broadcast];
        [self.captureSignals removeObjectForKey:connection];
        [self.session startRunning];
      }
    }
  }
}

@end
