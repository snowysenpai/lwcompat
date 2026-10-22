#include "imgui_hud.hpp"

#include "imgui.h"
#include "backends/imgui_impl_vulkan.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>


namespace {

struct LoaderContext {
    VkInstance instance = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;

    PFN_vkGetInstanceProcAddr gipa = nullptr;
    PFN_vkGetDeviceProcAddr gdpa = nullptr;
};


struct HudState {
    bool initialized = false;

    VkDevice device = VK_NULL_HANDLE;
    VkFormat format = VK_FORMAT_UNDEFINED;
    uint32_t image_count = 0;

    LoaderContext loader;

    std::chrono::steady_clock::time_point
        last_frame =
            std::chrono::steady_clock::now();

    std::chrono::steady_clock::time_point
        fps_window =
            std::chrono::steady_clock::now();

    uint32_t fps_frames = 0;
    float fps = 0.0f;

    std::chrono::steady_clock::time_point
        last_network_read =
            std::chrono::steady_clock::now()
            - std::chrono::seconds(5);

    int server = 0;
    float rtt = 0.0f;
    bool network_valid = false;

    // From network_feed.py: seconds since this TCP connection appeared and
    // whether it landed on the slow (~160 ms) path.
    int connection_age = 0;
    bool route_slow = false;

    VkSampler blur_sampler = VK_NULL_HANDLE;
    VkImageView blur_view = VK_NULL_HANDLE;
    VkDescriptorSet blur_descriptor = VK_NULL_HANDLE;
};


HudState g;
std::mutex g_mutex;


PFN_vkVoidFunction load_vulkan_function(
    const char* name,
    void* user_data
)
{
    auto* ctx =
        static_cast<LoaderContext*>(user_data);

    if (
        ctx->gdpa &&
        ctx->device != VK_NULL_HANDLE
    ) {
        PFN_vkVoidFunction fn =
            ctx->gdpa(
                ctx->device,
                name
            );

        if (fn)
            return fn;
    }

    if (
        ctx->gipa &&
        ctx->instance != VK_NULL_HANDLE
    ) {
        return ctx->gipa(
            ctx->instance,
            name
        );
    }

    return nullptr;
}


void check_vk_result(VkResult result)
{
    if (result < 0) {
        std::fprintf(
            stderr,
            "[LWCompat HUD] Vulkan error: %d\n",
            static_cast<int>(result)
        );
    }
}


std::string network_state_path()
{
    if (
        const char* cache =
            std::getenv("XDG_CACHE_HOME")
    ) {
        return std::string(cache)
            + "/lwcompat/network.txt";
    }

    if (
        const char* home =
            std::getenv("HOME")
    ) {
        return std::string(home)
            + "/.cache/lwcompat/network.txt";
    }

    return {};
}


void update_network()
{
    using Clock =
        std::chrono::steady_clock;

    const auto now = Clock::now();

    if (
        std::chrono::duration<double>(
            now - g.last_network_read
        ).count() < 0.25
    ) {
        return;
    }

    g.last_network_read = now;

    const std::string path =
        network_state_path();

    if (path.empty()) {
        g.network_valid = false;
        return;
    }

    std::ifstream file(path);

    if (!file.good()) {
        g.network_valid = false;
        return;
    }

    std::string line;
    std::getline(file, line);

    int server = 0;
    double rtt = 0.0;

    const int parsed =
        std::sscanf(
            line.c_str(),
            "#%d | RTT %lf ms",
            &server,
            &rtt
        );

    if (parsed == 2) {
        g.server = server;
        g.rtt = static_cast<float>(rtt);
        g.network_valid = true;

        const char* age = std::strstr(line.c_str(), "| Age ");
        g.connection_age = age ? std::atoi(age + 6) : 0;

        const char* route = std::strstr(line.c_str(), "| Route ");
        g.route_slow = route && std::strncmp(route + 8, "slow", 4) == 0;
    } else {
        g.network_valid = false;
    }
}


float update_fps_and_delta()
{
    using Clock =
        std::chrono::steady_clock;

    const auto now = Clock::now();

    float delta =
        std::chrono::duration<float>(
            now - g.last_frame
        ).count();

    g.last_frame = now;

    if (
        delta <= 0.0f ||
        delta > 1.0f
    ) {
        delta = 1.0f / 60.0f;
    }

    ++g.fps_frames;

    const float window =
        std::chrono::duration<float>(
            now - g.fps_window
        ).count();

    if (window >= 0.50f) {
        g.fps =
            static_cast<float>(
                g.fps_frames
            ) / window;

        g.fps_frames = 0;
        g.fps_window = now;
    }

    return delta;
}


ImU32 ping_color()
{
    if (!g.network_valid)
        return IM_COL32(
            160,
            170,
            180,
            255
        );

    if (g.rtt < 60.0f)
        return IM_COL32(
            70,
            220,
            140,
            255
        );

    if (g.rtt < 120.0f)
        return IM_COL32(
            245,
            190,
            65,
            255
        );

    return IM_COL32(
        245,
        90,
        90,
        255
    );
}


void shutdown_internal()
{
    if (!g.initialized)
        return;

    if (g.blur_descriptor != VK_NULL_HANDLE) {
        ImGui_ImplVulkan_RemoveTexture(
            g.blur_descriptor
        );

        g.blur_descriptor = VK_NULL_HANDLE;
        g.blur_sampler = VK_NULL_HANDLE;
        g.blur_view = VK_NULL_HANDLE;
    }

    ImGui_ImplVulkan_Shutdown();
    ImGui::DestroyContext();

    g = HudState{};
}

} // namespace


void lw_hud_get_rect(
    VkExtent2D extent,
    VkOffset2D* offset,
    VkExtent2D* size
)
{
    const float scale =
        std::clamp(
            static_cast<float>(extent.height) / 900.0f,
            0.85f,
            1.35f
        );

    const int32_t x =
        std::max(
            0,
            static_cast<int32_t>(
                static_cast<float>(extent.width) * 0.235f
            )
        );

    const int32_t y =
        std::max(
            0,
            static_cast<int32_t>(12.0f * scale)
        );

    uint32_t w =
        std::max(
            1u,
            static_cast<uint32_t>(300.0f * scale)
        );

    uint32_t h =
        std::max(
            1u,
            static_cast<uint32_t>(38.0f * scale)
        );

    if (static_cast<uint32_t>(x) >= extent.width)
        w = 1;
    else
        w = std::min(w, extent.width - static_cast<uint32_t>(x));

    if (static_cast<uint32_t>(y) >= extent.height)
        h = 1;
    else
        h = std::min(h, extent.height - static_cast<uint32_t>(y));

    if (offset) {
        offset->x = x;
        offset->y = y;
    }

    if (size) {
        size->width = w;
        size->height = h;
    }
}


bool lw_hud_ensure(
    VkInstance instance,
    VkPhysicalDevice physical_device,
    VkDevice device,
    VkQueue queue,
    uint32_t queue_family,
    VkFormat format,
    uint32_t image_count,
    PFN_vkGetInstanceProcAddr gipa,
    PFN_vkGetDeviceProcAddr gdpa
)
{
    std::lock_guard<std::mutex>
        lock(g_mutex);

    if (
        g.initialized &&
        g.device == device &&
        g.format == format &&
        g.image_count == image_count
    ) {
        return true;
    }

    if (g.initialized)
        shutdown_internal();

    g.loader.instance = instance;
    g.loader.device = device;
    g.loader.gipa = gipa;
    g.loader.gdpa = gdpa;

    if (
        !ImGui_ImplVulkan_LoadFunctions(
            VK_API_VERSION_1_3,
            load_vulkan_function,
            &g.loader
        )
    ) {
        std::fprintf(
            stderr,
            "[LWCompat HUD] "
            "ImGui Vulkan function loading failed\n"
        );

        return false;
    }

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();

    ImGuiIO& io = ImGui::GetIO();

    io.IniFilename = nullptr;
    io.LogFilename = nullptr;

    ImGuiStyle& style =
        ImGui::GetStyle();

    style.AntiAliasedLines = true;
    style.AntiAliasedFill = true;

    VkPipelineRenderingCreateInfoKHR
        rendering_info{};

    rendering_info.sType =
        VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;

    rendering_info.colorAttachmentCount = 1;
    rendering_info.pColorAttachmentFormats =
        &format;

    ImGui_ImplVulkan_InitInfo init{};

    init.ApiVersion =
        VK_API_VERSION_1_3;

    init.Instance =
        instance;

    init.PhysicalDevice =
        physical_device;

    init.Device =
        device;

    init.QueueFamily =
        queue_family;

    init.Queue =
        queue;

    init.DescriptorPoolSize =
        64;

    init.MinImageCount =
        std::max(
            2u,
            image_count
        );

    init.ImageCount =
        std::max(
            2u,
            image_count
        );

    init.MSAASamples =
        VK_SAMPLE_COUNT_1_BIT;

    init.UseDynamicRendering =
        true;

    init.PipelineRenderingCreateInfo =
        rendering_info;

    init.CheckVkResultFn =
        check_vk_result;

    if (!ImGui_ImplVulkan_Init(&init)) {
        ImGui::DestroyContext();

        std::fprintf(
            stderr,
            "[LWCompat HUD] "
            "ImGui Vulkan init failed\n"
        );

        return false;
    }

    g.initialized = true;
    g.device = device;
    g.format = format;
    g.image_count = image_count;

    g.last_frame =
        std::chrono::steady_clock::now();

    g.fps_window =
        g.last_frame;

    return true;
}


bool lw_hud_set_blur_texture(
    VkSampler sampler,
    VkImageView image_view
)
{
    std::lock_guard<std::mutex>
        lock(g_mutex);

    if (!g.initialized ||
        sampler == VK_NULL_HANDLE ||
        image_view == VK_NULL_HANDLE) {
        return false;
    }

    if (g.blur_descriptor != VK_NULL_HANDLE &&
        g.blur_sampler == sampler &&
        g.blur_view == image_view) {
        return true;
    }

    if (g.blur_descriptor != VK_NULL_HANDLE) {
        ImGui_ImplVulkan_RemoveTexture(
            g.blur_descriptor
        );

        g.blur_descriptor = VK_NULL_HANDLE;
    }

    VkDescriptorSet descriptor =
        ImGui_ImplVulkan_AddTexture(
            sampler,
            image_view,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        );

    if (descriptor == VK_NULL_HANDLE) {
        g.blur_sampler = VK_NULL_HANDLE;
        g.blur_view = VK_NULL_HANDLE;
        return false;
    }

    g.blur_sampler = sampler;
    g.blur_view = image_view;
    g.blur_descriptor = descriptor;

    return true;
}


void lw_hud_clear_blur_texture(
    VkImageView image_view
)
{
    std::lock_guard<std::mutex>
        lock(g_mutex);

    if (!g.initialized ||
        g.blur_descriptor == VK_NULL_HANDLE ||
        g.blur_view != image_view) {
        return;
    }

    ImGui_ImplVulkan_RemoveTexture(
        g.blur_descriptor
    );

    g.blur_descriptor = VK_NULL_HANDLE;
    g.blur_sampler = VK_NULL_HANDLE;
    g.blur_view = VK_NULL_HANDLE;
}


void lw_hud_render(
    VkCommandBuffer command_buffer,
    VkExtent2D extent,
    bool blur_ready
)
{
    std::lock_guard<std::mutex>
        lock(g_mutex);

    if (!g.initialized)
        return;

    const float delta =
        update_fps_and_delta();

    update_network();

    ImGuiIO& io =
        ImGui::GetIO();

    io.DisplaySize =
        ImVec2(
            static_cast<float>(
                extent.width
            ),
            static_cast<float>(
                extent.height
            )
        );

    io.DisplayFramebufferScale =
        ImVec2(
            1.0f,
            1.0f
        );

    io.DeltaTime =
        delta;

    ImGui_ImplVulkan_NewFrame();
    ImGui::NewFrame();

    ImDrawList* draw =
        ImGui::GetForegroundDrawList();

    const float scale =
        std::clamp(
            static_cast<float>(extent.height) / 900.0f,
            0.85f,
            1.35f
        );

    // Keep the exact position/size that already looked right in-game.
    const float x =
        static_cast<float>(extent.width) * 0.235f;

    const float y =
        12.0f * scale;

    const float w =
        300.0f * scale;

    const float h =
        38.0f * scale;

    const float radius =
        9.0f * scale;

    const ImVec2 p0(
        x,
        y
    );

    const ImVec2 p1(
        x + w,
        y + h
    );

    // Soft shadow.
    draw->AddRectFilled(
        ImVec2(
            p0.x + 2.0f * scale,
            p0.y + 3.0f * scale
        ),
        ImVec2(
            p1.x + 2.0f * scale,
            p1.y + 3.0f * scale
        ),
        IM_COL32(
            0,
            0,
            0,
            60
        ),
        radius
    );

    const bool use_blur =
        blur_ready &&
        g.blur_descriptor != VK_NULL_HANDLE;

    if (use_blur) {
        draw->AddImageRounded(
            (ImTextureID)g.blur_descriptor,
            p0,
            p1,
            ImVec2(0.0f, 0.0f),
            ImVec2(1.0f, 1.0f),
            IM_COL32(255, 255, 255, 255),
            radius
        );
    }

    // Dark glass tint. With blur active we can keep this lighter.
    draw->AddRectFilled(
        p0,
        p1,
        IM_COL32(
            8,
            14,
            22,
            use_blur ? 108 : 155
        ),
        radius
    );

    // Very subtle border.
    draw->AddRect(
        p0,
        p1,
        IM_COL32(
            255,
            255,
            255,
            32
        ),
        radius,
        0,
        1.0f
    );

    const ImU32 status_color =
        ping_color();

    draw->AddCircleFilled(
        ImVec2(
            x + 17.0f * scale,
            y + h * 0.5f
        ),
        4.5f * scale,
        status_color
    );

    char server_text[32];

    if (g.network_valid) {
        std::snprintf(
            server_text,
            sizeof(server_text),
            "#%d",
            g.server
        );
    } else {
        std::snprintf(
            server_text,
            sizeof(server_text),
            "#----"
        );
    }

    char ping_text[32];

    if (g.network_valid) {
        std::snprintf(
            ping_text,
            sizeof(ping_text),
            "%.0f ms",
            g.rtt
        );
    } else {
        std::snprintf(
            ping_text,
            sizeof(ping_text),
            "-- ms"
        );
    }

    char fps_text[32];

    std::snprintf(
        fps_text,
        sizeof(fps_text),
        "%.0f FPS",
        g.fps
    );

    const float font_size =
        15.0f * scale;

    const float text_y =
        y
        + (
            h - font_size
        ) * 0.5f
        - 1.0f * scale;

    ImFont* font =
        ImGui::GetFont();

    draw->AddText(
        font,
        font_size,
        ImVec2(
            x + 31.0f * scale,
            text_y
        ),
        IM_COL32(
            225,
            232,
            240,
            255
        ),
        server_text
    );

    draw->AddText(
        font,
        font_size,
        ImVec2(
            x + 104.0f * scale,
            text_y
        ),
        status_color,
        ping_text
    );

    draw->AddText(
        font,
        font_size,
        ImVec2(
            x + 205.0f * scale,
            text_y
        ),
        IM_COL32(
            225,
            232,
            240,
            255
        ),
        fps_text
    );

    // Slow-route warning during the first seconds of a slow connection, so a
    // reconnect can be tried before timing-sensitive actions.
    constexpr int kSlowRouteBannerSeconds = 13;

    if (g.network_valid && g.route_slow
        && g.connection_age < kSlowRouteBannerSeconds) {
        const float by = y + h + 6.0f * scale;
        const float bh = 26.0f * scale;

        draw->AddRectFilled(
            ImVec2(x, by),
            ImVec2(x + w, by + bh),
            IM_COL32(150, 35, 35, 215),
            radius
        );

        char banner[96];
        std::snprintf(
            banner,
            sizeof(banner),
            "SLOW ROUTE %.0f ms - try reconnecting",
            g.rtt
        );

        const float banner_font = 13.0f * scale;

        draw->AddText(
            ImGui::GetFont(),
            banner_font,
            ImVec2(x + 10.0f * scale, by + (bh - banner_font) * 0.5f),
            IM_COL32(255, 240, 240, 255),
            banner
        );
    }

    ImGui::Render();

    ImGui_ImplVulkan_RenderDrawData(
        ImGui::GetDrawData(),
        command_buffer
    );
}


void lw_hud_shutdown(
    VkDevice device
)
{
    std::lock_guard<std::mutex>
        lock(g_mutex);

    if (
        !g.initialized ||
        g.device != device
    ) {
        return;
    }

    shutdown_internal();
}
