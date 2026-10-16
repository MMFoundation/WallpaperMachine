#include "RenderCommon/ScenePassInfo.hpp"

namespace wallpaper
{

// Out of line on purpose. A renderer finds this interface on a graph step with
// a cross-cast from the graph's pass type, and that cast compares type
// information. Defining the destructor here makes this the one translation unit
// that emits the vtable and typeinfo, so the cast cannot see two copies from
// two static archives and fail.
ScenePassInfo::~ScenePassInfo() = default;

} // namespace wallpaper
