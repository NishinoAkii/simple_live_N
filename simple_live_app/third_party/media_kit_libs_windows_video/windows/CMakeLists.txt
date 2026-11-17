# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)

# This option is read by the other packages which are part of package:media_kit.
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)

set(PROJECT_NAME "media_kit_libs_windows_video")
project(${PROJECT_NAME} LANGUAGES CXX)

# Deal with MSVC incompatiblity
add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

# ------------------------------------------------------------------------------
# SimpleLive: libmpv built from mpv bcde6b9 (2026-11-12), which has the D3D11
# render API used by third_party/media_kit_video. Same archive layout as the
# original (include/mpv/*.h, libmpv.dll.a, libmpv-2.dll). ANGLE is not needed.
set(LIBMPV "mpv-dev-x86_64-20261112-git-bcde6b9.7z")
set(LIBMPV_URL "https://github.com/Predidit/libmpv-win32-video-cmake/releases/download/202611120335/${LIBMPV}")
set(LIBMPV_SHA256 "297de0494d7a8687ce42acda1e3a63b0ce86c099f09e0627020558c44aae323b")

set(LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${LIBMPV}")
# Named after the build, so an older libmpv extracted in an existing build
# directory is never picked up.
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv-20261112-bcde6b9")

if(EXISTS "${LIBMPV_ARCHIVE}")
  file(SHA256 "${LIBMPV_ARCHIVE}" LIBMPV_ARCHIVE_SHA256)
  if(NOT LIBMPV_ARCHIVE_SHA256 STREQUAL LIBMPV_SHA256)
    message(STATUS "${LIBMPV}: checksum mismatch, downloading again.")
    file(REMOVE "${LIBMPV_ARCHIVE}")
  endif()
endif()

if(NOT EXISTS "${LIBMPV_ARCHIVE}")
  message(STATUS "Downloading ${LIBMPV_URL}...")
  file(
    DOWNLOAD "${LIBMPV_URL}" "${LIBMPV_ARCHIVE}"
    EXPECTED_HASH SHA256=${LIBMPV_SHA256}
    STATUS LIBMPV_DOWNLOAD_STATUS
  )
  list(GET LIBMPV_DOWNLOAD_STATUS 0 LIBMPV_DOWNLOAD_CODE)
  if(NOT LIBMPV_DOWNLOAD_CODE EQUAL 0)
    file(REMOVE "${LIBMPV_ARCHIVE}")
    message(FATAL_ERROR "Downloading ${LIBMPV} failed: ${LIBMPV_DOWNLOAD_STATUS}")
  endif()
endif()

# Extract while configuring, so the headers and import library exist before
# media_kit_video compiles.
if(NOT EXISTS "${LIBMPV_SRC}/libmpv-2.dll" OR
   NOT EXISTS "${LIBMPV_SRC}/libmpv.dll.a" OR
   NOT EXISTS "${LIBMPV_SRC}/include/mpv/render_d3d11.h")
  file(REMOVE_RECURSE "${LIBMPV_SRC}")
  file(MAKE_DIRECTORY "${LIBMPV_SRC}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xf "${LIBMPV_ARCHIVE}"
    WORKING_DIRECTORY "${LIBMPV_SRC}"
    RESULT_VARIABLE LIBMPV_EXTRACT_RESULT
  )
  if(NOT LIBMPV_EXTRACT_RESULT EQUAL 0 OR
     NOT EXISTS "${LIBMPV_SRC}/include/mpv/render_d3d11.h")
    file(REMOVE_RECURSE "${LIBMPV_SRC}")
    message(FATAL_ERROR "Extracting ${LIBMPV} failed.")
  endif()
endif()

# Read by third_party/media_kit_video (configured after this package).
set(MEDIA_KIT_LIBMPV_DIR "${LIBMPV_SRC}" CACHE INTERNAL "libmpv headers, import library and DLL")

# ------------------------------------------------------------------------------
set(PLUGIN_NAME "media_kit_libs_windows_video_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h"
  "media_kit_libs_windows_video_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET
  hidden
)
target_compile_definitions(
  ${PLUGIN_NAME}
  PRIVATE
  FLUTTER_PLUGIN_IMPL
)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

set(
  media_kit_libs_windows_video_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll"
  PARENT_SCOPE
)
