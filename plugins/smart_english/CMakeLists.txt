cmake_minimum_required(VERSION 3.12)
project(rime-smart-english)

add_library(rime-smart-english-objs OBJECT
  smart_english.cc
  smart_english_filter.cc
  smart_english_index.cc)

if(BUILD_SHARED_LIBS)
  set_target_properties(rime-smart-english-objs
    PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()

set(plugin_name rime-smart-english PARENT_SCOPE)
set(plugin_objs $<TARGET_OBJECTS:rime-smart-english-objs> PARENT_SCOPE)
set(plugin_deps ${rime_library} PARENT_SCOPE)
set(plugin_modules "smart_english" PARENT_SCOPE)
