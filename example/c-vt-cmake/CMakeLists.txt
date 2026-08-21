cmake_minimum_required(VERSION 3.19)
project(c-vt-cmake LANGUAGES C)

include(FetchContent)
FetchContent_Declare(noctty
    GIT_REPOSITORY https://github.com/amanthanvi/noctty.git
    GIT_TAG main
)
FetchContent_MakeAvailable(noctty)

add_executable(c_vt_cmake src/main.c)
target_link_libraries(c_vt_cmake PRIVATE ghostty-vt)
