#include "sunshine/platform/common.h"
#include "sunshine/platform/macos/av_audio.h"
#include "sunshine/platform/macos/av_video.h"

#include <algorithm>
#include <bitset>
#include <fstream>

#include <pwd.h>

#include "sunshine/config.h"
#include "sunshine/main.h"
#include "sunshine/task_pool.h"

#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>

#include <iomanip>
#include <memory>
#include <sstream>

namespace fs = std::filesystem;

namespace platf {
using namespace std::literals;

struct avmic_attr_t : public mic_t {
  AVAudio *mic;

  ~avmic_attr_t() {
    [mic release];
  }

  capture_e sample(std::vector<std::int16_t> &sample_in) override {
    auto sample_size = sample_in.size();

    uint32_t length        = 0;
    void *byteSampleBuffer = TPCircularBufferTail(&mic->audioSampleBuffer, &length);

    while(length < sample_size * sizeof(std::int16_t)) {
      [mic.samplesArrivedSignal wait];
      byteSampleBuffer = TPCircularBufferTail(&mic->audioSampleBuffer, &length);
    }

    const int16_t *sampleBuffer = (int16_t *)byteSampleBuffer;
    std::vector<int16_t> vectorBuffer(sampleBuffer, sampleBuffer + sample_size);

    std::copy_n(std::begin(vectorBuffer), sample_size, std::begin(sample_in));

    TPCircularBufferConsume(&mic->audioSampleBuffer, sample_size * sizeof(std::int16_t));

    return capture_e::ok;
  }
};

struct macos_audio_control_t : public audio_control_t {
  AVCaptureDevice *device;

public:
  int set_sink(const std::string &sink) override {
    device = [AVAudio findMicrophone:[NSString stringWithUTF8String:sink.c_str()]];

    if(device)
      return 0;
    else {
      BOOST_LOG(warning) << "seting microphone to '"sv << sink << "' failed. Please set a valid input source in the Sunshine config."sv;
      BOOST_LOG(warning) << "Available inputs:"sv;

      for(NSString *name in [AVAudio microphoneNames]) {
        BOOST_LOG(warning) << "\t"sv << [name UTF8String];
      }

      return -1;
    }
  }

  std::unique_ptr<mic_t> microphone(const std::uint8_t *mapping, int channels, std::uint32_t sample_rate, std::uint32_t frame_size) override {
    auto mic = std::make_unique<avmic_attr_t>();
    mic->mic = [[AVAudio alloc] init];

    if([mic->mic setupMicrophone:device sampleRate:sample_rate frameSize:frame_size channels:channels]) {
      return nullptr;
    }

    return mic;
  }

  std::optional<sink_t> sink_info() override {
    sink_t sink;

    return sink;
  }
};

struct avdisplay_img_t : public img_t {
  // We have to retain the DataRef to an image for the image buffer
  // and release it when the image buffer is no longer needed
  // XXX: this should be replaced by a smart pointer with CFRelease as custom deallocator
  CFDataRef dataRef = nullptr;

  ~avdisplay_img_t() override {
    if(dataRef != NULL)
      CFRelease(dataRef);
    data = nullptr;
  }
};

struct avdisplay_attr_t : public display_t {
  AVVideo *display;

  ~avdisplay_attr_t() {
    [display release];
  }

  capture_e capture(snapshot_cb_t &&snapshot_cb, std::shared_ptr<img_t> img, bool *cursor) override {
    __block auto next_img = std::move(img);

    [display capture:^(CGImageRef imgRef) {
      CGDataProviderRef dataProvider = CGImageGetDataProvider(imgRef);

      CFDataRef dataRef = CGDataProviderCopyData(dataProvider);

      // XXX: next_img->img should be moved to a smart pointer with
      // the CFRelease as custon deallocator
      if((std::static_pointer_cast<avdisplay_img_t>(next_img))->dataRef != nullptr) {
        CFRelease((std::static_pointer_cast<avdisplay_img_t>(next_img))->dataRef);
      }

      (std::static_pointer_cast<avdisplay_img_t>(next_img))->dataRef = dataRef;
      next_img->data                                                 = (uint8_t *)CFDataGetBytePtr(dataRef);

      next_img->width       = CGImageGetWidth(imgRef);
      next_img->height      = CGImageGetHeight(imgRef);
      next_img->row_pitch   = CGImageGetBytesPerRow(imgRef);
      next_img->pixel_pitch = CGImageGetBitsPerPixel(imgRef) / 8;

      next_img = snapshot_cb(next_img);

      return next_img != nullptr;
    }];

    [display.captureStopped wait];

    return capture_e::ok;
  }

  std::shared_ptr<img_t> alloc_img() override {
    return std::make_shared<avdisplay_img_t>();
  }

  int dummy_img(img_t *img) override {
    auto imgRef = CGDisplayCreateImage(CGMainDisplayID());

    if(!imgRef)
      return -1;

    CGDataProviderRef dataProvider = CGImageGetDataProvider(imgRef);

    CFDataRef dataRef = CGDataProviderCopyData(dataProvider);

    ((avdisplay_img_t *)img)->dataRef = dataRef;
    img->data                         = (uint8_t *)CFDataGetBytePtr(dataRef);

    img->width       = CGImageGetWidth(imgRef);
    img->height      = CGImageGetHeight(imgRef);
    img->row_pitch   = CGImageGetBytesPerRow(imgRef);
    img->pixel_pitch = CGImageGetBitsPerPixel(imgRef) / 8;

    return 0;
  }
};

std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type, int framerate) {
  if(hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
    BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
    return nullptr;
  }

  auto result = std::make_shared<avdisplay_attr_t>();

  int capture_width  = 0;
  int capture_height = 0;

  if(config::video.sw.width.has_value() && config::video.sw.height.has_value()) {
    capture_width  = config::video.sw.width.value();
    capture_height = config::video.sw.height.value();
    BOOST_LOG(info) << "Capturing with "sv << capture_width << "x"sv << capture_height;
  }

  result->display = [[AVVideo alloc] initWithFrameRate:framerate width:capture_width height:capture_height];

  if(!result->display) {
    BOOST_LOG(error) << "Video setup failed."sv;
    return nullptr;
  }

  auto tmp_image = result->alloc_img();
  if(result->dummy_img(tmp_image.get())) {
    result->width  = capture_width;
    result->height = capture_height;
  }
  else {
    result->width  = tmp_image->width;
    result->height = tmp_image->height;
  }

  return result;
}

std::unique_ptr<audio_control_t> audio_control() {
  return std::make_unique<macos_audio_control_t>();
}
}
