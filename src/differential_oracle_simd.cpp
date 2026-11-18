// Oracle-only runtime dispatch observation. Built with vt.cpp's exact flags.
#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "differential_oracle_simd.cpp"
#include <hwy/foreach_target.h>
#include <hwy/highway.h>
#include <simdutf.h>
#include <stddef.h>
#include <string.h>

HWY_BEFORE_NAMESPACE();
namespace noctty_oracle {
namespace HWY_NAMESPACE {
const char* HighwayTarget() { return hwy::TargetName(HWY_TARGET); }
}
}
HWY_AFTER_NAMESPACE();

#if HWY_ONCE
namespace noctty_oracle {
HWY_EXPORT(HighwayTarget);
const char* SelectedHighwayTarget() {
  return HWY_DYNAMIC_DISPATCH(HighwayTarget)();
}
}
extern "C" const char* oracle_highway_target() {
  return noctty_oracle::SelectedHighwayTarget();
}
extern "C" size_t oracle_simdutf_name(char* output, size_t capacity) {
  const auto name = simdutf::get_active_implementation()->name();
  const size_t count = name.size() < capacity ? name.size() : capacity;
  memcpy(output, name.data(), count);
  return count;
}
#endif
