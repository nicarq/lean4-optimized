# Copyright (c) 2026 Nico Arqueros. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Authors: Nico Arqueros

set(LEAN_METAL_SUPPORTED OFF)
if(APPLE AND CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang)$")
  set(LEAN_METAL_SUPPORTED ON)
endif()
option(USE_METAL "Build the optional Metal array evaluator" ${LEAN_METAL_SUPPORTED})
if(USE_METAL)
  if(NOT LEAN_METAL_SUPPORTED)
    message(FATAL_ERROR "Metal requires an Apple platform and a Clang C++ compiler")
  endif()
  string(APPEND LEAN_EXTRA_LINKER_FLAGS " -framework Metal -framework Foundation")
endif()
