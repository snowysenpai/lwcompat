cmake_minimum_required(VERSION 3.20)

project(lwcompat_hud_spike LANGUAGES CXX)

find_package(Vulkan REQUIRED)

set(IMGUI_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/vendor/imgui"
)

add_library(lwcompat_hud_spike SHARED
    layer_rect.cpp
    imgui_hud.cpp

    ${IMGUI_DIR}/imgui.cpp
    ${IMGUI_DIR}/imgui_draw.cpp
    ${IMGUI_DIR}/imgui_tables.cpp
    ${IMGUI_DIR}/imgui_widgets.cpp

    ${IMGUI_DIR}/backends/imgui_impl_vulkan.cpp
)

target_compile_features(
    lwcompat_hud_spike
    PRIVATE
    cxx_std_20
)

target_compile_definitions(
    lwcompat_hud_spike
    PRIVATE
    IMGUI_IMPL_VULKAN_NO_PROTOTYPES
)

target_include_directories(
    lwcompat_hud_spike
    PRIVATE
    ${Vulkan_INCLUDE_DIRS}
    ${IMGUI_DIR}
    ${IMGUI_DIR}/backends
    ${CMAKE_CURRENT_SOURCE_DIR}
)

set_target_properties(
    lwcompat_hud_spike
    PROPERTIES
    OUTPUT_NAME "lwcompat_hud_spike"
)

configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/VK_LAYER_LWCOMPAT_hud_spike.json.in"
    "${CMAKE_CURRENT_BINARY_DIR}/VK_LAYER_LWCOMPAT_hud_spike.json"
    @ONLY
)
