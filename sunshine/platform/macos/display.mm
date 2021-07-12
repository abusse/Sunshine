#include "sunshine/platform/common.h"
#include "sunshine/platform/macos/av_audio.h"
#include "sunshine/platform/macos/av_video.h"

#include <fstream>
#include <bitset>
#include <algorithm>
 
#include <pwd.h>

#include "sunshine/task_pool.h"
#include "sunshine/config.h"
#include "sunshine/main.h"

#import <ApplicationServices/ApplicationServices.h>
#import <AVFoundation/AVFoundation.h>

#include <sstream>
#include <iomanip>

namespace fs = std::filesystem;

namespace platf
{
using namespace std::literals;

struct avmic_attr_t : public mic_t {
  AVAudio *mic;

  ~avmic_attr_t() {
    [mic release];
  }

  capture_e sample(std::vector<std::int16_t> &sample_in) override {
    auto sample_size = sample_in.size();

    uint32_t length = 0;
    void *byteSampleBuffer = TPCircularBufferTail(&mic->audioSampleBuffer, &length);
    
    while (length < sample_size * sizeof(std::int16_t)) {
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
public:
  int set_sink(const std::string &sink) override{
    BOOST_LOG(warning) << "audio_control_t::set_sink() unimplemented: "sv << sink;
    return 0;
  }

  std::unique_ptr<mic_t> microphone(const std::uint8_t *mapping, int channels, std::uint32_t sample_rate, std::uint32_t frame_size) override{
    BOOST_LOG(info) << "Available inputs:"sv;

    for (NSString *name in [AVAudio microphoneNames]) {
      BOOST_LOG(info) << "\t"sv << [name UTF8String];
    }

    auto mic = std::make_unique<avmic_attr_t>();

    const char *audio_sink = "";

    if (!config::audio.sink.empty()) {
      audio_sink = config::audio.sink.c_str();
    }

    mic->mic = [[AVAudio alloc]init];

    if ([mic->mic setupMicrophoneWithName:[NSString stringWithUTF8String:audio_sink] sampleRate:sample_rate frameSize:frame_size channels:channels]) {
      BOOST_LOG(error) << "opening microphone '"sv << audio_sink << "' failed. Please set a valid input source in the Sunshine config."sv;
      BOOST_LOG(error) << "Available inputs:"sv;

      for (NSString *name in [AVAudio microphoneNames]) {
        BOOST_LOG(error) << "\t"sv << [name UTF8String];
      }

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
  CFDataRef img;

  ~avdisplay_img_t() override {
    if (img != NULL)
      CFRelease(img);
    data = nullptr;
  }
};

struct avdisplay_attr_t : public display_t {
  AVVideo *display;

  ~avdisplay_attr_t() {
    [display release];
  }

  capture_e snapshot(img_t *img_out_base, std::chrono::milliseconds timeout, bool cursor) override {
    auto img_out = (avdisplay_img_t *)img_out_base;

    auto img = [display getSnapshot:CMTimeMake(timeout.count(), 1000) showCursor:cursor];

    CGDataProviderRef dataProvider = CGImageGetDataProvider(img);

    CFDataRef dataRef = CGDataProviderCopyData(dataProvider);

    if (img_out->img != NULL) {
      CFRelease(img_out->img);
    }

    img_out->img = dataRef;
    img_out->data = (uint8_t *)CFDataGetBytePtr(dataRef);

    img_out->width = CGImageGetWidth(img);
    img_out->height = CGImageGetHeight(img);
    img_out->row_pitch = CGImageGetBytesPerRow(img);
    img_out->pixel_pitch = CGImageGetBitsPerPixel(img) / 8;

    CGImageRelease(img);

    return capture_e::ok;
  }

  std::shared_ptr<img_t> alloc_img() override {
    return std::make_shared<avdisplay_img_t>();
  }

  int dummy_img(img_t *img) override {
    snapshot(img, 0s, true);
    return 0;
  }
};

std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type) {
  if (hwdevice_type != platf::mem_type_e::system) {
    BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
    return nullptr;
  }

  auto result = std::make_shared<avdisplay_attr_t>();

  result->display = [[AVVideo alloc] init];

  int capture_width = 0;
  int capture_height = 0;

  if (config::video.sw.width.has_value() && config::video.sw.height.has_value()) {
    capture_width = config::video.sw.width.value();
    capture_height = config::video.sw.height.value();
    BOOST_LOG(info) << "Capturing with "sv << capture_width << "x"sv << capture_height;
  }
  
  if (![result->display setupVideo:capture_width
                            height:capture_height]) {
    BOOST_LOG(error) << "Video setup failed."sv;
    return nullptr;
  }

  auto tmp_image = result->alloc_img();
  result->dummy_img(tmp_image.get());
  result->width = tmp_image->width;
  result->height = tmp_image->height;

  return result;
}

std::unique_ptr<audio_control_t> audio_control() {
  return std::make_unique<macos_audio_control_t>();
}
}
