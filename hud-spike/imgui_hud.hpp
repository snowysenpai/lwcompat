#pragma once

#include <vulkan/vulkan.h>

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
);

void lw_hud_get_rect(
    VkExtent2D extent,
    VkOffset2D* offset,
    VkExtent2D* size
);

bool lw_hud_set_blur_texture(
    VkSampler sampler,
    VkImageView image_view
);

void lw_hud_clear_blur_texture(
    VkImageView image_view
);

void lw_hud_render(
    VkCommandBuffer command_buffer,
    VkExtent2D extent,
    bool blur_ready
);

void lw_hud_shutdown(
    VkDevice device
);
