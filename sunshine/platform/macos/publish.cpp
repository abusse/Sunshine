#include "sunshine/main.h"
#include "sunshine/platform/common.h"

namespace platf::publish {
using namespace std::literals;

std::unique_ptr<::platf::deinit_t> start() {
  BOOST_LOG(warning) << "Publishing not implemented for MacOS"sv;

  return nullptr;
}
} // namespace platf::publish
