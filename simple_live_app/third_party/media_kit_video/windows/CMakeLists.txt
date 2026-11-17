# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.
#
# SimpleLive: mpv renders through its D3D11 render API into a shared D3D11
# texture (renderer adapted from Predidit/media-kit), no ANGLE. libmpv comes from
# third_party/media_kit_libs_windows_video, which sets MEDIA_KIT_LIBMPV_DIR.

cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "media_kit_video")
set(CMAKE_CXX_STANDARD 17)
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "media_kit_video_plugin")

# Deal with MSVC incompatiblity
add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

if(MEDIA_KIT_LIBS_AVAILABLE AND MEDIA_KIT_LIBMPV_DIR)
  add_library(
    ${PLUGIN_NAME} SHARED
    "d3d11_renderer.cc"
    "media_kit_video_plugin_c_api.cc"
    "media_kit_video_plugin.cc"
    "video_output_manager.cc"
    "video_output.cc"
    "utils.cc"
    ${PLUGIN_SOURCES}
  )

  apply_standard_settings(${PLUGIN_NAME})

  set_target_properties(
    ${PLUGIN_NAME} PROPERTIES
    CXX_VISIBILITY_PRESET hidden
  )
  target_compile_definitions(
    ${PLUGIN_NAME} PRIVATE
    FLUTTER_PLUGIN_IMPL
  )
  # The sources contain non-ASCII characters; /WX turns C4819 into an error on
  # non-UTF-8 code pages.
  target_compile_options(${PLUGIN_NAME} PRIVATE "/utf-8")

  target_include_directories(
    ${PLUGIN_NAME}
    INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include"
    PRIVATE "${MEDIA_KIT_LIBMPV_DIR}/include"
  )

  target_link_libraries(
    ${PLUGIN_NAME} PRIVATE
    flutter
    flutter_wrapper_plugin
    "${MEDIA_KIT_LIBMPV_DIR}/libmpv.dll.a"
    d3d11
    dxgi
  )
else()
  message(NOTICE "media_kit: WARNING: package:media_kit_libs_*** not found.")

  add_library(
    ${PLUGIN_NAME} SHARED
    "media_kit_video_plugin_c_api.cc"
    ${PLUGIN_SOURCES}
  )

  apply_standard_settings(${PLUGIN_NAME})

  set_target_properties(
    ${PLUGIN_NAME} PROPERTIES
    CXX_VISIBILITY_PRESET hidden
  )

  target_compile_definitions(
    ${PLUGIN_NAME} PRIVATE
    FLUTTER_PLUGIN_IMPL

    # Add macro to indicate that libmpv from package:media_kit_libs_*** is not found.
    "MEDIA_KIT_LIBS_NOT_FOUND=1"
  )

  target_include_directories(
    ${PLUGIN_NAME} INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  )

  target_link_libraries(
    ${PLUGIN_NAME} PRIVATE
    flutter
    flutter_wrapper_plugin
  )
endif()

set(
  media_kit_video_bundled_libraries
  ""
  PARENT_SCOPE
)
