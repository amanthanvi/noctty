cmake_minimum_required(VERSION 3.19)
project(c-vt-cmake-static LANGUAGES C)

include(FetchContent)
FetchContent_Declare(koreterm
    GIT_REPOSITORY https://github.com/richardsonvix/noctty_terminal.git
    GIT_TAG main
)
set(GHOSTTY_ZIG_BUILD_FLAGS "-Dsimd=false" CACHE STRING "" FORCE)
FetchContent_MakeAvailable(koreterm)

add_executable(c_vt_cmake_static src/main.c)
target_link_libraries(c_vt_cmake_static PRIVATE ghostty-vt-static)
