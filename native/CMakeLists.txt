# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.13)
project(fboard_native LANGUAGES C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FB_DEPS REQUIRED IMPORTED_TARGET
  libpulse libavformat libavcodec libavutil libswresample x11)

add_library(fboard_native SHARED media.c audio.c input.c)
set_target_properties(fboard_native PROPERTIES C_STANDARD 11 C_VISIBILITY_PRESET hidden)
target_compile_options(fboard_native PRIVATE -Wall -Wextra -Wno-unused-parameter
  "$<$<NOT:$<CONFIG:Debug>>:-O2>")
target_link_libraries(fboard_native PRIVATE PkgConfig::FB_DEPS pthread m)
