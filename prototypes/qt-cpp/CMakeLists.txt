cmake_minimum_required(VERSION 3.24)
project(Montage VERSION 0.1 LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(Qt6 6.7 REQUIRED COMPONENTS Core Gui GuiPrivate Quick ShaderTools LinguistTools)
qt_standard_project_setup(REQUIRES 6.8 I18N_SOURCE_LANGUAGE en I18N_TRANSLATED_LANGUAGES fr)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil libswscale libswresample)
pkg_check_modules(RUBBERBAND REQUIRED IMPORTED_TARGET rubberband)
find_package(onnxruntime REQUIRED)
find_package(whisper REQUIRED)
find_package(ggml REQUIRED)

qt_add_executable(Montage MACOSX_BUNDLE
  src/main.cpp
  src/Metrics.h src/Metrics.mm
  src/ClipDecoder.h src/ClipDecoder.cpp
  src/Compositor.h src/Compositor.mm
  src/Engine.h src/Engine.cpp
  src/PreviewItem.h src/PreviewItem.mm
  src/Exporter.h src/Exporter.mm
  src/TimelineCanvas.h src/TimelineCanvas.cpp
  src/AudioEngine.h src/AudioEngine.cpp src/miniaudio_impl.c
  src/Segmenter.h src/Segmenter.cpp
  src/Transcriber.h src/Transcriber.cpp
)

set_source_files_properties(src/miniaudio_impl.c PROPERTIES COMPILE_OPTIONS "-x;objective-c")

target_include_directories(Montage PRIVATE src third_party)

qt_add_qml_module(Montage
  URI Montage
  VERSION 1.0
  QML_FILES qml/Main.qml qml/TimelineView.qml
  SOURCES src/PreviewItem.h src/TimelineCanvas.h
  NO_RESOURCE_TARGET_PATH
)

qt_add_shaders(Montage "shaders"
  PREFIX "/shaders"
  FILES shaders/composite.vert shaders/composite.frag
)

qt_add_translations(Montage TS_FILES i18n/montage_fr.ts RESOURCE_PREFIX "/i18n" LUPDATE_OPTIONS -no-obsolete)

target_link_libraries(Montage PRIVATE
  Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Quick
  PkgConfig::FFMPEG PkgConfig::RUBBERBAND
  onnxruntime::onnxruntime whisper ggml::ggml ggml::ggml-base
  "-framework Metal" "-framework CoreVideo" "-framework CoreMedia" "-framework VideoToolbox"
  "-framework CoreAudio" "-framework AudioToolbox" "-framework Foundation" "-framework IOSurface"
)

set_target_properties(Montage PROPERTIES
  MACOSX_BUNDLE_GUI_IDENTIFIER fr.solona.montage.qtproto
  MACOSX_BUNDLE_BUNDLE_NAME Montage
)
