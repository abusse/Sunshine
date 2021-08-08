#ifndef av_img_t_h
#define av_img_t_h

#include "sunshine/platform/common.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

namespace platf {

struct av_img_t : public img_t {
  // We have to retain the DataRef to an image for the image buffer
  // and release it when the image buffer is no longer needed
  // XXX: this should be replaced by a smart pointer with CFRelease as custom deallocator
  CVPixelBufferRef pixelBuffer   = nullptr;
  CMSampleBufferRef sampleBuffer = nullptr;
  int extraPixels[4]             = { 0, 0, 0, 0 };
  bool isPooled                  = false;

  ~av_img_t();
};

} // namespace platf

#endif /* av_img_t_h */
