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

  self.capture = false;

  self.displayID        = displayID;
  self.frameWidth       = 1920;
  self.frameHeight      = 1080;
  self.minFrameDuration = CMTimeMake(1, frameRate);
  self.captureStopped   = [[NSCondition alloc] init];

  return self;
}

- (void)dealloc {
  self.videoConnection = nil;
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

- (bool)capture:(frameCallbackBlock)frameCallback {
  self.session = [[AVCaptureSession alloc] init];

  AVCaptureScreenInput *screenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:self.displayID];
  [screenInput setMinFrameDuration:self.minFrameDuration];

  if([self.session canAddInput:screenInput]) {
    [self.session addInput:screenInput];
  }
  else {
    [screenInput release];
    return nil;
  }

  AVCaptureVideoDataOutput *movieOutput = [[AVCaptureVideoDataOutput alloc] init];


  [movieOutput setVideoSettings:@{
    (NSString *)kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:kPixelFormat],
    (NSString *)kCVPixelBufferWidthKey: [NSNumber numberWithInt:self.frameWidth],
    (NSString *)kCVPixelBufferExtendedPixelsRightKey: [NSNumber numberWithInt:self.paddingRight],
    (NSString *)kCVPixelBufferExtendedPixelsLeftKey: [NSNumber numberWithInt:self.paddingLeft],
    (NSString *)kCVPixelBufferExtendedPixelsTopKey: [NSNumber numberWithInt:self.paddingTop],
    (NSString *)kCVPixelBufferExtendedPixelsBottomKey: [NSNumber numberWithInt:self.paddingBottom],
    (NSString *)kCVPixelBufferHeightKey: [NSNumber numberWithInt:self.frameHeight]
  }];


  dispatch_queue_attr_t qos       = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
  dispatch_queue_t recordingQueue = dispatch_queue_create("videoCaptureQueue", qos);

  [movieOutput setSampleBufferDelegate:self queue:recordingQueue];

  if([self.session canAddOutput:movieOutput]) {
    [self.session addOutput:movieOutput];
  }
  else {
    [movieOutput release];
    return nil;
  }

  self.videoConnection = [movieOutput connectionWithMediaType:AVMediaTypeVideo];

  self.frameCallback = frameCallback;
  self.capture       = true;

  [self.session startRunning];

  return true;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  if(connection == self.videoConnection && self.capture) {
    if(!self.frameCallback(sampleBuffer)) {
      [self.session stopRunning];
      // this ensures that we do not try to forward frames that
      // are eventually still queued for processing
      self.capture = false;
      [self.captureStopped broadcast];
    }
  }
}

@end
