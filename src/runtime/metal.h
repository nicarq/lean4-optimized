/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Nico Arqueros
*/
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lean {
bool metal_available();
bool metal_map_u64(std::string const & source, std::vector<uint64_t> const & input,
                   std::vector<uint64_t> const & captures, std::vector<uint64_t> & output);
}
