//
// Created by loki on 6/21/19.
//

#include "sunshine/platform/common.h"

#include <fstream>

#include <X11/X.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/Xrandr.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <xcb/shm.h>
#include <xcb/xfixes.h>

#include "sunshine/config.h"
#include "sunshine/main.h"
#include "sunshine/task_pool.h"

#include "vaapi.h"

using namespace std::literals;

namespace platf {

void freeImage(XImage *);
void freeX(XFixesCursorImage *);

using xcb_connect_t = util::safe_ptr<xcb_connection_t, xcb_disconnect>;
using xcb_img_t     = util::c_ptr<xcb_shm_get_image_reply_t>;

using xdisplay_t = util::safe_ptr_v2<Display, int, XCloseDisplay>;
using ximg_t     = util::safe_ptr<XImage, freeImage>;
using xcursor_t  = util::safe_ptr<XFixesCursorImage, freeX>;

using crtc_info_t   = util::safe_ptr<_XRRCrtcInfo, XRRFreeCrtcInfo>;
using output_info_t = util::safe_ptr<_XRROutputInfo, XRRFreeOutputInfo>;
using screen_res_t  = util::safe_ptr<_XRRScreenResources, XRRFreeScreenResources>;

class shm_id_t {
public:
  shm_id_t() : id { -1 } {}
  shm_id_t(int id) : id { id } {}
  shm_id_t(shm_id_t &&other) noexcept : id(other.id) {
    other.id = -1;
  }

  ~shm_id_t() {
    if(id != -1) {
      shmctl(id, IPC_RMID, nullptr);
      id = -1;
    }
  }
  int id;
};

class shm_data_t {
public:
  shm_data_t() : data { (void *)-1 } {}
  shm_data_t(void *data) : data { data } {}

  shm_data_t(shm_data_t &&other) noexcept : data(other.data) {
    other.data = (void *)-1;
  }

  ~shm_data_t() {
    if((std::uintptr_t)data != -1) {
      shmdt(data);
    }
  }

  void *data;
};

struct x11_img_t : public img_t {
  ximg_t img;
};

struct shm_img_t : public img_t {
  ~shm_img_t() override {
    delete[] data;
    data = nullptr;
  }
};

void blend_cursor(Display *display, img_t &img, int offsetX, int offsetY) {
  xcursor_t overlay { XFixesGetCursorImage(display) };

  if(!overlay) {
    BOOST_LOG(error) << "Couldn't get cursor from XFixesGetCursorImage"sv;
    return;
  }

  overlay->x -= overlay->xhot;
  overlay->y -= overlay->yhot;

  overlay->x -= offsetX;
  overlay->y -= offsetY;

  overlay->x = std::max((short)0, overlay->x);
  overlay->y = std::max((short)0, overlay->y);

  auto pixels = (int *)img.data;

  auto screen_height = img.height;
  auto screen_width  = img.width;

  auto delta_height = std::min<uint16_t>(overlay->height, std::max(0, screen_height - overlay->y));
  auto delta_width  = std::min<uint16_t>(overlay->width, std::max(0, screen_width - overlay->x));
  for(auto y = 0; y < delta_height; ++y) {
    auto overlay_begin = &overlay->pixels[y * overlay->width];
    auto overlay_end   = &overlay->pixels[y * overlay->width + delta_width];

    auto pixels_begin = &pixels[(y + overlay->y) * (img.row_pitch / img.pixel_pitch) + overlay->x];

    std::for_each(overlay_begin, overlay_end, [&](long pixel) {
      int *pixel_p = (int *)&pixel;

      auto colors_in = (uint8_t *)pixels_begin;

      auto alpha = (*(uint *)pixel_p) >> 24u;
      if(alpha == 255) {
        *pixels_begin = *pixel_p;
      }
      else {
        auto colors_out = (uint8_t *)pixel_p;
        colors_in[0]    = colors_out[0] + (colors_in[0] * (255 - alpha) + 255 / 2) / 255;
        colors_in[1]    = colors_out[1] + (colors_in[1] * (255 - alpha) + 255 / 2) / 255;
        colors_in[2]    = colors_out[2] + (colors_in[2] * (255 - alpha) + 255 / 2) / 255;
      }
      ++pixels_begin;
    });
  }
}

struct x11_attr_t : public display_t {
  std::chrono::nanoseconds delay;

  xdisplay_t xdisplay;
  Window xwindow;
  XWindowAttributes xattr;

  mem_type_e mem_type;

  /*
   * Last X (NOT the streamed monitor!) size.
   * This way we can trigger reinitialization if the dimensions changed while streaming
   */
  // int env_width, env_height;

  x11_attr_t(mem_type_e mem_type) : xdisplay { XOpenDisplay(nullptr) }, xwindow {}, xattr {}, mem_type { mem_type } {
    XInitThreads();
  }

  int init(int framerate, const std::string &output_name) {
    if(!xdisplay) {
      BOOST_LOG(error) << "Could not open X11 display"sv;
      return -1;
    }

    delay = std::chrono::nanoseconds { 1s } / framerate;

    xwindow = DefaultRootWindow(xdisplay.get());

    refresh();

    int streamedMonitor = -1;
    if(!output_name.empty()) {
      streamedMonitor = (int)util::from_view(output_name);
    }

    if(streamedMonitor != -1) {
      BOOST_LOG(info) << "Configuring selected monitor ("sv << streamedMonitor << ") to stream"sv;
      screen_res_t screenr { XRRGetScreenResources(xdisplay.get(), xwindow) };
      int output = screenr->noutput;

      output_info_t result;
      int monitor = 0;
      for(int x = 0; x < output; ++x) {
        output_info_t out_info { XRRGetOutputInfo(xdisplay.get(), screenr.get(), screenr->outputs[x]) };
        if(out_info && out_info->connection == RR_Connected) {
          if(monitor++ == streamedMonitor) {
            result = std::move(out_info);
            break;
          }
        }
      }

      if(!result) {
        BOOST_LOG(error) << "Could not stream display number ["sv << streamedMonitor << "], there are only ["sv << monitor << "] displays."sv;
        return -1;
      }

      crtc_info_t crt_info { XRRGetCrtcInfo(xdisplay.get(), screenr.get(), result->crtc) };
      BOOST_LOG(info)
        << "Streaming display: "sv << result->name << " with res "sv << crt_info->width << 'x' << crt_info->height << " offset by "sv << crt_info->x << 'x' << crt_info->y;

      width    = crt_info->width;
      height   = crt_info->height;
      offset_x = crt_info->x;
      offset_y = crt_info->y;
    }
    else {
      width  = xattr.width;
      height = xattr.height;
    }

    env_width  = xattr.width;
    env_height = xattr.height;

    return 0;
  }

  /**
   * Called when the display attributes should change.
   */
  void refresh() {
    XGetWindowAttributes(xdisplay.get(), xwindow, &xattr); //Update xattr's
  }

  capture_e capture(snapshot_cb_t &&snapshot_cb, std::shared_ptr<img_t> img, bool *cursor) override {
    auto next_frame = std::chrono::steady_clock::now();

    while(img) {
      auto now = std::chrono::steady_clock::now();

      if(next_frame > now) {
        std::this_thread::sleep_for((next_frame - now) / 3 * 2);
      }
      while(next_frame > now) {
        now = std::chrono::steady_clock::now();
      }
      next_frame = now + delay;

      auto status = snapshot(img.get(), 1000ms, *cursor);
      switch(status) {
      case platf::capture_e::reinit:
      case platf::capture_e::error:
        return status;
      case platf::capture_e::timeout:
        std::this_thread::sleep_for(1ms);
        continue;
      case platf::capture_e::ok:
        img = snapshot_cb(img);
        break;
      default:
        BOOST_LOG(error) << "Unrecognized capture status ["sv << (int)status << ']';
        return status;
      }
    }

    return capture_e::ok;
  }

  capture_e snapshot(img_t *img_out_base, std::chrono::milliseconds timeout, bool cursor) {
    refresh();

    //The whole X server changed, so we gotta reinit everything
    if(xattr.width != env_width || xattr.height != env_height) {
      BOOST_LOG(warning) << "X dimensions changed in non-SHM mode, request reinit"sv;
      return capture_e::reinit;
    }
    XImage *img { XGetImage(xdisplay.get(), xwindow, offset_x, offset_y, width, height, AllPlanes, ZPixmap) };

    auto img_out         = (x11_img_t *)img_out_base;
    img_out->width       = img->width;
    img_out->height      = img->height;
    img_out->data        = (uint8_t *)img->data;
    img_out->row_pitch   = img->bytes_per_line;
    img_out->pixel_pitch = img->bits_per_pixel / 8;
    img_out->img.reset(img);

    if(cursor) {
      blend_cursor(xdisplay.get(), *img_out_base, offset_x, offset_y);
    }

    return capture_e::ok;
  }

  std::shared_ptr<img_t> alloc_img() override {
    return std::make_shared<x11_img_t>();
  }

  std::shared_ptr<hwdevice_t> make_hwdevice(pix_fmt_e pix_fmt) override {
    if(mem_type == mem_type_e::vaapi) {
      return egl::make_hwdevice(width, height);
    }

    return std::make_shared<hwdevice_t>();
  }

  int dummy_img(img_t *img) override {
    snapshot(img, 0s, true);
    return 0;
  }
};

struct shm_attr_t : public x11_attr_t {
  xdisplay_t shm_xdisplay; // Prevent race condition with x11_attr_t::xdisplay
  xcb_connect_t xcb;
  xcb_screen_t *display;
  std::uint32_t seg;

  shm_id_t shm_id;

  shm_data_t data;

  util::TaskPool::task_id_t refresh_task_id;

  void delayed_refresh() {
    refresh();

    refresh_task_id = task_pool.pushDelayed(&shm_attr_t::delayed_refresh, 2s, this).task_id;
  }

  shm_attr_t(mem_type_e mem_type) : x11_attr_t(mem_type), shm_xdisplay { XOpenDisplay(nullptr) } {
    refresh_task_id = task_pool.pushDelayed(&shm_attr_t::delayed_refresh, 2s, this).task_id;
  }

  ~shm_attr_t() override {
    while(!task_pool.cancel(refresh_task_id))
      ;
  }

  capture_e capture(snapshot_cb_t &&snapshot_cb, std::shared_ptr<img_t> img, bool *cursor) override {
    auto next_frame = std::chrono::steady_clock::now();

    while(img) {
      auto now = std::chrono::steady_clock::now();

      if(next_frame > now) {
        std::this_thread::sleep_for((next_frame - now) / 3 * 2);
      }
      while(next_frame > now) {
        now = std::chrono::steady_clock::now();
      }
      next_frame = now + delay;

      auto status = snapshot(img.get(), 1000ms, *cursor);
      switch(status) {
      case platf::capture_e::reinit:
      case platf::capture_e::error:
        return status;
      case platf::capture_e::timeout:
        std::this_thread::sleep_for(1ms);
        continue;
      case platf::capture_e::ok:
        img = snapshot_cb(img);
        break;
      default:
        BOOST_LOG(error) << "Unrecognized capture status ["sv << (int)status << ']';
        return status;
      }
    }

    return capture_e::ok;
  }

  capture_e snapshot(img_t *img, std::chrono::milliseconds timeout, bool cursor) {
    //The whole X server changed, so we gotta reinit everything
    if(xattr.width != env_width || xattr.height != env_height) {
      BOOST_LOG(warning) << "X dimensions changed in SHM mode, request reinit"sv;
      return capture_e::reinit;
    }
    else {
      auto img_cookie = xcb_shm_get_image_unchecked(xcb.get(), display->root, offset_x, offset_y, width, height, ~0, XCB_IMAGE_FORMAT_Z_PIXMAP, seg, 0);

      xcb_img_t img_reply { xcb_shm_get_image_reply(xcb.get(), img_cookie, nullptr) };
      if(!img_reply) {
        BOOST_LOG(error) << "Could not get image reply"sv;
        return capture_e::reinit;
      }

      std::copy_n((std::uint8_t *)data.data, frame_size(), img->data);

      if(cursor) {
        blend_cursor(shm_xdisplay.get(), *img, offset_x, offset_y);
      }

      return capture_e::ok;
    }
  }

  std::shared_ptr<img_t> alloc_img() override {
    auto img         = std::make_shared<shm_img_t>();
    img->width       = width;
    img->height      = height;
    img->pixel_pitch = 4;
    img->row_pitch   = img->pixel_pitch * width;
    img->data        = new std::uint8_t[height * img->row_pitch];

    return img;
  }

  int dummy_img(platf::img_t *img) override {
    return 0;
  }

  int init(int framerate, const std::string &output_name) {
    if(x11_attr_t::init(framerate, output_name)) {
      return 1;
    }

    shm_xdisplay.reset(XOpenDisplay(nullptr));
    xcb.reset(xcb_connect(nullptr, nullptr));
    if(xcb_connection_has_error(xcb.get())) {
      return -1;
    }

    if(!xcb_get_extension_data(xcb.get(), &xcb_shm_id)->present) {
      BOOST_LOG(error) << "Missing SHM extension"sv;

      return -1;
    }

    auto iter = xcb_setup_roots_iterator(xcb_get_setup(xcb.get()));
    display   = iter.data;
    seg       = xcb_generate_id(xcb.get());

    shm_id.id = shmget(IPC_PRIVATE, frame_size(), IPC_CREAT | 0777);
    if(shm_id.id == -1) {
      BOOST_LOG(error) << "shmget failed"sv;
      return -1;
    }

    xcb_shm_attach(xcb.get(), seg, shm_id.id, false);
    data.data = shmat(shm_id.id, nullptr, 0);

    if((uintptr_t)data.data == -1) {
      BOOST_LOG(error) << "shmat failed"sv;

      return -1;
    }

    return 0;
  }

  std::uint32_t frame_size() {
    return width * height * 4;
  }
};

std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type, const std::string &output_name, int framerate) {
  if(hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::vaapi && hwdevice_type != platf::mem_type_e::cuda) {
    BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
    return nullptr;
  }

  // Attempt to use shared memory X11 to avoid copying the frame
  auto shm_disp = std::make_shared<shm_attr_t>(hwdevice_type);

  auto status = shm_disp->init(framerate, output_name);
  if(status > 0) {
    // x11_attr_t::init() failed, don't bother trying again.
    return nullptr;
  }

  if(status == 0) {
    return shm_disp;
  }

  // Fallback
  auto x11_disp = std::make_shared<x11_attr_t>(hwdevice_type);
  if(x11_disp->init(framerate, output_name)) {
    return nullptr;
  }

  return x11_disp;
}

std::vector<std::string> display_names() {
  BOOST_LOG(info) << "Detecting connected monitors"sv;

  xdisplay_t xdisplay { XOpenDisplay(nullptr) };
  if(!xdisplay) {
    return {};
  }

  auto xwindow = DefaultRootWindow(xdisplay.get());
  screen_res_t screenr { XRRGetScreenResources(xdisplay.get(), xwindow) };
  int output = screenr->noutput;

  int monitor = 0;
  for(int x = 0; x < output; ++x) {
    output_info_t out_info { XRRGetOutputInfo(xdisplay.get(), screenr.get(), screenr->outputs[x]) };
    if(out_info && out_info->connection == RR_Connected) {
      ++monitor;
    }
  }

  std::vector<std::string> names;
  names.reserve(monitor);

  for(auto x = 0; x < monitor; ++x) {
    BOOST_LOG(fatal) << x;
    names.emplace_back(std::to_string(x));
  }

  return names;
}

void freeImage(XImage *p) {
  XDestroyImage(p);
}
void freeX(XFixesCursorImage *p) {
  XFree(p);
}
} // namespace platf
