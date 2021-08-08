#include "sunshine/platform/common.h"
#include "sunshine/platform/macos/av_img_t.h"
#include "sunshine/platform/macos/av_video.h"
#include "sunshine/platform/macos/nv12_zero_device.h"

#include "sunshine/config.h"
#include "sunshine/main.h"

namespace fs = std::filesystem;

namespace platf {
using namespace std::literals;

av_img_t::~av_img_t() {
  if(pixelBuffer != NULL) {
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    if(!isPooled) {
      CFRelease(pixelBuffer);
    }
  }

  if(sampleBuffer != nullptr) {
    CFRelease(sampleBuffer);
  }
  data = nullptr;
}

struct av_display_t : public display_t {
  AVVideo *display;
  CGDirectDisplayID display_id;

  ~av_display_t() {
    [display release];
  }

  capture_e capture(snapshot_cb_t &&snapshot_cb, std::shared_ptr<img_t> img, bool *cursor) override {
    __block auto img_next = std::move(img);

    auto signal = [display capture:^(CMSampleBufferRef sampleBuffer) {
      auto av_img_next = std::static_pointer_cast<av_img_t>(img_next);

      CFRetain(sampleBuffer);

      CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
      CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

      // XXX: next_img->img should be moved to a smart pointer with
      // the CFRelease as custon deallocator
      if(av_img_next->pixelBuffer != nullptr)
        CVPixelBufferUnlockBaseAddress(av_img_next->pixelBuffer, 0);

      if(av_img_next->sampleBuffer != nullptr)
        CFRelease(av_img_next->sampleBuffer);

      av_img_next->sampleBuffer = sampleBuffer;
      av_img_next->pixelBuffer  = pixelBuffer;
      av_img_next->isPooled     = true;
      img_next->data            = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);

      size_t extraPixels[4];
      CVPixelBufferGetExtendedPixels(pixelBuffer, &extraPixels[0], &extraPixels[1], &extraPixels[2], &extraPixels[3]);

      img_next->width       = CVPixelBufferGetWidth(pixelBuffer) + extraPixels[0] + extraPixels[1];
      img_next->height      = CVPixelBufferGetHeight(pixelBuffer) + extraPixels[2] + extraPixels[3];
      img_next->row_pitch   = CVPixelBufferGetBytesPerRow(pixelBuffer);
      img_next->pixel_pitch = img_next->row_pitch / img_next->width;

      img_next = snapshot_cb(img_next);

      return img_next != nullptr;
    }];

    [signal wait];

    return capture_e::ok;
  }

  std::shared_ptr<img_t> alloc_img() override {
    return std::make_shared<av_img_t>();
  }

  std::shared_ptr<hwdevice_t> make_hwdevice(pix_fmt_e pix_fmt) override {
    if(pix_fmt == pix_fmt_e::yuv420p) {
      display.pixelFormat = kCVPixelFormatType_32BGRA;

      return std::make_shared<hwdevice_t>();
    }
    else if(pix_fmt == pix_fmt_e::nv12) {
      auto device = std::make_shared<nv12_zero_device>();

      device->init(static_cast<void *>(display), setResolution, setPixelFormat);

      return device;
    }
    else {
      BOOST_LOG(error) << "Unsupported Pixel Format."sv;
      return nullptr;
    }
  }

  int dummy_img(img_t *img) override {
    auto signal = [display capture:^(CMSampleBufferRef sampleBuffer) {
      auto av_img = (av_img_t *)img;

      CFRetain(sampleBuffer);

      CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
      CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

      // XXX: next_img->img should be moved to a smart pointer with
      // the CFRelease as custon deallocator
      if(av_img->pixelBuffer != nullptr)
        CVPixelBufferUnlockBaseAddress(((av_img_t *)img)->pixelBuffer, 0);

      if(av_img->sampleBuffer != nullptr)
        CFRelease(av_img->sampleBuffer);


      av_img->sampleBuffer = sampleBuffer;
      av_img->pixelBuffer  = pixelBuffer;
      av_img->isPooled     = true;
      img->data            = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);

      size_t extraPixels[4];
      CVPixelBufferGetExtendedPixels(pixelBuffer, &extraPixels[0], &extraPixels[1], &extraPixels[2], &extraPixels[3]);

      img->width       = CVPixelBufferGetWidth(pixelBuffer) + extraPixels[0] + extraPixels[1];
      img->height      = CVPixelBufferGetHeight(pixelBuffer) + extraPixels[2] + extraPixels[3];
      img->row_pitch   = CVPixelBufferGetBytesPerRow(pixelBuffer);
      img->pixel_pitch = img->row_pitch / img->width;

      return false;
    }];

    [signal wait];

    return 0;
  }

  /**
   * A bridge from the pure C++ code of the hwdevice_t class to the pure Objective C code.
   *
   * display --> an opaque pointer to an object of this class
   * width --> the intended capture width
   * height --> the intended capture height
   */
  static void setResolution(void *display, int width, int height) {
    [static_cast<AVVideo *>(display) setFrameWidth:width frameHeight:height];
  }

  static void setPixelFormat(void *display, OSType pixelFormat) {
    static_cast<AVVideo *>(display).pixelFormat = pixelFormat;
  }
};

std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type, const std::string &display_name, int framerate) {
  if(hwdevice_type != platf::mem_type_e::system) {
    BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
    return nullptr;
  }

  auto result = std::make_shared<av_display_t>();

  result->display_id = CGMainDisplayID();
  if(!display_name.empty()) {
    auto display_array = [AVVideo displayNames];

    for(NSDictionary *item in display_array) {
      NSString *name = item[@"name"];
      if(name.UTF8String == display_name) {
        NSNumber *display_id = item[@"id"];
        result->display_id   = [display_id unsignedIntValue];
      }
    }
  }

  result->display = [[AVVideo alloc] initWithDisplay:result->display_id frameRate:framerate];

  if(!result->display) {
    BOOST_LOG(error) << "Video setup failed."sv;
    return nullptr;
  }

  auto tmp_image = result->alloc_img();
  if(result->dummy_img(tmp_image.get())) {
    BOOST_LOG(error) << "Failed to capture initial frame"sv;
    return nullptr;
  }
  result->width  = tmp_image->width;
  result->height = tmp_image->height;

  return result;
}

std::vector<std::string> display_names() {
  __block std::vector<std::string> display_names;

  auto display_array = [AVVideo displayNames];

  display_names.reserve([display_array count]);
  [display_array enumerateObjectsUsingBlock:^(NSDictionary *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
    NSString *name = obj[@"name"];
    display_names.push_back(name.UTF8String);
  }];

  return display_names;
}
}
