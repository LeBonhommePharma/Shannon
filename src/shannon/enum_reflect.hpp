// enum_reflect.hpp — P2996 reflection hatch for Backend names
//
// Only compiled when the implementation actually ships `<meta>` and the
// reflection operator. The constexpr table in types.hpp remains the production
// name source (fail-closed "UNKNOWN"). This header exists so GCC-with-reflection
// CI can prove the table covers every enumerator.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/cxx26.hpp"
#include "shannon/types.hpp"

#include <string_view>

#if defined(__cpp_impl_reflection) && defined(SHANNON_CXX26_HAS_INCLUDE_META)
#include <meta>

namespace shannon::cxx26 {

template <class E>
[[nodiscard]] constexpr std::string_view reflected_enumerator_name(E value) noexcept {
    template for (constexpr auto r : std::meta::enumerators_of(^^E)) {
        if (value == [:r:]) {
            return std::meta::identifier_of(r);
        }
    }
    return "UNKNOWN";
}

}  // namespace shannon::cxx26
#endif
