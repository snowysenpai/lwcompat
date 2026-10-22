#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

#include "imgui_hud.hpp"



static constexpr const char* LAYER_NAME =
    "VK_LAYER_LWCOMPAT_hud_spike";

static constexpr const char* LOG_PATH =
    "/tmp/lwcompat-hud-spike.log";


template <typename T>
static void* dispatch_key(T object)
{
    if (!object)
        return nullptr;

    return *reinterpret_cast<void**>(object);
}


static void log_line(const char* format, ...)
{
    static std::mutex log_mutex;
    std::lock_guard<std::mutex> lock(log_mutex);

    FILE* fp = std::fopen(LOG_PATH, "a");
    if (!fp)
        return;

    va_list args;
    va_start(args, format);

    std::vfprintf(fp, format, args);
    std::fprintf(fp, "\n");

    va_end(args);
    std::fclose(fp);
}


struct InstanceDispatch {
    VkInstance instance = VK_NULL_HANDLE;

    PFN_vkGetInstanceProcAddr gipa = nullptr;
    PFN_vkDestroyInstance destroy_instance = nullptr;

    PFN_vkEnumeratePhysicalDevices enumerate_physical_devices =
        nullptr;
};


struct DeviceDispatch {
    VkDevice device = VK_NULL_HANDLE;
    VkPhysicalDevice physical_device = VK_NULL_HANDLE;
    VkInstance instance = VK_NULL_HANDLE;

    PFN_vkGetInstanceProcAddr gipa = nullptr;
    PFN_vkGetDeviceProcAddr gdpa = nullptr;

    PFN_vkDestroyDevice destroy_device = nullptr;

    PFN_vkGetDeviceQueue get_device_queue = nullptr;
    PFN_vkGetDeviceQueue2 get_device_queue2 = nullptr;

    PFN_vkQueuePresentKHR queue_present = nullptr;
    PFN_vkQueueSubmit queue_submit = nullptr;

    PFN_vkCreateSwapchainKHR create_swapchain = nullptr;
    PFN_vkDestroySwapchainKHR destroy_swapchain = nullptr;
    PFN_vkGetSwapchainImagesKHR get_swapchain_images = nullptr;

    PFN_vkCreateImageView create_image_view = nullptr;
    PFN_vkDestroyImageView destroy_image_view = nullptr;

    PFN_vkCreateImage create_image = nullptr;
    PFN_vkDestroyImage destroy_image = nullptr;
    PFN_vkGetImageMemoryRequirements get_image_memory_requirements = nullptr;
    PFN_vkAllocateMemory allocate_memory = nullptr;
    PFN_vkFreeMemory free_memory = nullptr;
    PFN_vkBindImageMemory bind_image_memory = nullptr;

    PFN_vkCreateSampler create_sampler = nullptr;
    PFN_vkDestroySampler destroy_sampler = nullptr;

    PFN_vkCreateCommandPool create_command_pool = nullptr;
    PFN_vkDestroyCommandPool destroy_command_pool = nullptr;
    PFN_vkAllocateCommandBuffers allocate_command_buffers = nullptr;

    PFN_vkCreateSemaphore create_semaphore = nullptr;
    PFN_vkDestroySemaphore destroy_semaphore = nullptr;

    PFN_vkCreateFence create_fence = nullptr;
    PFN_vkDestroyFence destroy_fence = nullptr;
    PFN_vkWaitForFences wait_for_fences = nullptr;
    PFN_vkResetFences reset_fences = nullptr;

    PFN_vkResetCommandBuffer reset_command_buffer = nullptr;
    PFN_vkBeginCommandBuffer begin_command_buffer = nullptr;
    PFN_vkEndCommandBuffer end_command_buffer = nullptr;

    PFN_vkCmdPipelineBarrier cmd_pipeline_barrier = nullptr;
    PFN_vkCmdBlitImage cmd_blit_image = nullptr;

    PFN_vkCmdBeginRendering cmd_begin_rendering = nullptr;
    PFN_vkCmdEndRendering cmd_end_rendering = nullptr;
    PFN_vkCmdClearAttachments cmd_clear_attachments = nullptr;

    PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR
        get_surface_capabilities = nullptr;

    PFN_vkGetPhysicalDeviceMemoryProperties
        get_memory_properties = nullptr;

    PFN_vkGetPhysicalDeviceFormatProperties
        get_format_properties = nullptr;
};


struct QueueInfo {
    VkDevice device = VK_NULL_HANDLE;
    uint32_t family = UINT32_MAX;
};


struct SwapchainState {
    std::mutex mutex;

    VkDevice device = VK_NULL_HANDLE;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;

    VkFormat format = VK_FORMAT_UNDEFINED;
    VkExtent2D extent{};
    uint32_t layers = 1;

    bool overlay_supported = false;
    bool blur_supported = false;

    VkImage blur_image = VK_NULL_HANDLE;
    VkDeviceMemory blur_memory = VK_NULL_HANDLE;
    VkImageView blur_view = VK_NULL_HANDLE;
    VkSampler blur_sampler = VK_NULL_HANDLE;
    VkExtent2D blur_extent{};
    bool blur_layout_initialized = false;

    std::vector<VkImage> images;
    std::vector<VkImageView> views;

    uint32_t queue_family = UINT32_MAX;
    VkCommandPool command_pool = VK_NULL_HANDLE;

    std::vector<VkCommandBuffer> command_buffers;
    std::vector<VkSemaphore> semaphores;
    std::vector<VkFence> fences;

    bool present_resources_ready = false;
};


static std::mutex g_mutex;

static std::unordered_map<VkInstance, InstanceDispatch>
    g_instances;

static std::unordered_map<void*, VkInstance>
    g_instance_keys;

static std::unordered_map<VkPhysicalDevice, VkInstance>
    g_phys_instances;

static std::unordered_map<VkDevice, DeviceDispatch>
    g_devices;

static std::unordered_map<void*, VkDevice>
    g_device_keys;

static std::unordered_map<VkQueue, QueueInfo>
    g_queues;

static std::unordered_map<
    VkSwapchainKHR,
    std::shared_ptr<SwapchainState>
> g_swapchains;

static std::atomic<uint64_t> g_present_count{0};


static bool get_device_dispatch(
    VkDevice device,
    DeviceDispatch& out
)
{
    std::lock_guard<std::mutex> lock(g_mutex);

    auto it = g_devices.find(device);

    if (it == g_devices.end())
        return false;

    out = it->second;
    return true;
}


static bool find_device_local_memory_type(
    const DeviceDispatch& d,
    uint32_t type_bits,
    uint32_t& out_index
)
{
    if (!d.get_memory_properties)
        return false;

    VkPhysicalDeviceMemoryProperties props{};

    d.get_memory_properties(
        d.physical_device,
        &props
    );

    for (uint32_t i = 0;
         i < props.memoryTypeCount;
         ++i) {

        const bool allowed =
            (type_bits & (1u << i)) != 0;

        const bool device_local =
            (props.memoryTypes[i].propertyFlags &
             VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0;

        if (allowed && device_local) {
            out_index = i;
            return true;
        }
    }

    // Extremely conservative fallback for unusual integrated-memory systems.
    for (uint32_t i = 0;
         i < props.memoryTypeCount;
         ++i) {

        if ((type_bits & (1u << i)) != 0) {
            out_index = i;
            return true;
        }
    }

    return false;
}


static void destroy_blur_resources_locked(
    SwapchainState& state,
    const DeviceDispatch& d
)
{
    if (state.blur_view != VK_NULL_HANDLE)
        lw_hud_clear_blur_texture(state.blur_view);

    if (state.blur_sampler && d.destroy_sampler) {
        d.destroy_sampler(
            state.device,
            state.blur_sampler,
            nullptr
        );
    }

    if (state.blur_view && d.destroy_image_view) {
        d.destroy_image_view(
            state.device,
            state.blur_view,
            nullptr
        );
    }

    if (state.blur_image && d.destroy_image) {
        d.destroy_image(
            state.device,
            state.blur_image,
            nullptr
        );
    }

    if (state.blur_memory && d.free_memory) {
        d.free_memory(
            state.device,
            state.blur_memory,
            nullptr
        );
    }

    state.blur_image = VK_NULL_HANDLE;
    state.blur_memory = VK_NULL_HANDLE;
    state.blur_view = VK_NULL_HANDLE;
    state.blur_sampler = VK_NULL_HANDLE;
    state.blur_extent = {};
    state.blur_layout_initialized = false;
}


static bool init_blur_resources_locked(
    SwapchainState& state,
    const DeviceDispatch& d
)
{
    if (!state.blur_supported)
        return false;

    if (state.blur_image != VK_NULL_HANDLE)
        return true;

    VkOffset2D hud_offset{};
    VkExtent2D hud_size{};

    lw_hud_get_rect(
        state.extent,
        &hud_offset,
        &hud_size
    );

    // Quarter-resolution capture gives a frosted-glass blur after
    // linear downsampling + linear ImGui upsampling.
    state.blur_extent.width =
        std::max(1u, hud_size.width / 4u);

    state.blur_extent.height =
        std::max(1u, hud_size.height / 4u);

    VkImageCreateInfo image_info{};
    image_info.sType =
        VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;

    image_info.imageType =
        VK_IMAGE_TYPE_2D;

    image_info.format =
        state.format;

    image_info.extent = {
        state.blur_extent.width,
        state.blur_extent.height,
        1
    };

    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = VK_SAMPLE_COUNT_1_BIT;
    image_info.tiling = VK_IMAGE_TILING_OPTIMAL;

    image_info.usage =
        VK_IMAGE_USAGE_TRANSFER_DST_BIT |
        VK_IMAGE_USAGE_SAMPLED_BIT;

    image_info.sharingMode =
        VK_SHARING_MODE_EXCLUSIVE;

    image_info.initialLayout =
        VK_IMAGE_LAYOUT_UNDEFINED;

    if (d.create_image(
            state.device,
            &image_info,
            nullptr,
            &state.blur_image
        ) != VK_SUCCESS) {

        log_line(
            "[LWCompat HUD] blur vkCreateImage failed"
        );

        destroy_blur_resources_locked(state, d);
        state.blur_supported = false;
        return false;
    }

    VkMemoryRequirements requirements{};

    d.get_image_memory_requirements(
        state.device,
        state.blur_image,
        &requirements
    );

    uint32_t memory_type = 0;

    if (!find_device_local_memory_type(
            d,
            requirements.memoryTypeBits,
            memory_type
        )) {

        log_line(
            "[LWCompat HUD] blur device-local memory type not found"
        );

        destroy_blur_resources_locked(state, d);
        state.blur_supported = false;
        return false;
    }

    VkMemoryAllocateInfo allocate_info{};
    allocate_info.sType =
        VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;

    allocate_info.allocationSize =
        requirements.size;

    allocate_info.memoryTypeIndex =
        memory_type;

    if (d.allocate_memory(
            state.device,
            &allocate_info,
            nullptr,
            &state.blur_memory
        ) != VK_SUCCESS) {

        log_line(
            "[LWCompat HUD] blur vkAllocateMemory failed"
        );

        destroy_blur_resources_locked(state, d);
        state.blur_supported = false;
        return false;
    }

    if (d.bind_image_memory(
            state.device,
            state.blur_image,
            state.blur_memory,
            0
        ) != VK_SUCCESS) {

        log_line(
            "[LWCompat HUD] blur vkBindImageMemory failed"
        );

        destroy_blur_resources_locked(state, d);
        state.blur_supported = false;
        return false;
    }

    VkImageViewCreateInfo view_info{};
    view_info.sType =
        VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;

    view_info.image = state.blur_image;
    view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = state.format;

    view_info.components = {
        VK_COMPONENT_SWIZZLE_IDENTITY,
        VK_COMPONENT_SWIZZLE_IDENTITY,
        VK_COMPONENT_SWIZZLE_IDENTITY,
        VK_COMPONENT_SWIZZLE_IDENTITY
    };

    view_info.subresourceRange.aspectMask =
        VK_IMAGE_ASPECT_COLOR_BIT;

    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    if (d.create_image_view(
            state.device,
            &view_info,
            nullptr,
            &state.blur_view
        ) != VK_SUCCESS) {

        log_line(
            "[LWCompat HUD] blur vkCreateImageView failed"
        );

        destroy_blur_resources_locked(state, d);
        state.blur_supported = false;
        return false;
    }

    VkSamplerCreateInfo sampler_info{};
    sampler_info.sType =
        VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;

    sampler_info.magFilter = VK_FILTER_LINEAR;
    sampler_info.minFilter = VK_FILTER_LINEAR;
    sampler_info.mipmapMode =
        VK_SAMPLER_MIPMAP_MODE_NEAREST;

    sampler_info.addressModeU =
        VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;

    sampler_info.addressModeV =
        VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;

    sampler_info.addressModeW =
        VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;

    sampler_info.mipLodBias = 0.0f;
    sampler_info.anisotropyEnable = VK_FALSE;
    sampler_info.compareEnable = VK_FALSE;
    sampler_info.minLod = 0.0f;
    sampler_info.maxLod = 0.0f;
    sampler_info.borderColor =
        VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;

    if (d.create_sampler(
            state.device,
            &sampler_info,
            nullptr,
            &state.blur_sampler
        ) != VK_SUCCESS) {

        log_line(
            "[LWCompat HUD] blur vkCreateSampler failed"
        );

        destroy_blur_resources_locked(state, d);
        state.blur_supported = false;
        return false;
    }

    log_line(
        "[LWCompat HUD] blur resources ready: %ux%u -> %ux%u",
        hud_size.width,
        hud_size.height,
        state.blur_extent.width,
        state.blur_extent.height
    );

    return true;
}


static VkLayerInstanceCreateInfo*
find_instance_chain(
    const VkInstanceCreateInfo* create_info
)
{
    auto* base =
        reinterpret_cast<const VkBaseInStructure*>(
            create_info->pNext
        );

    while (base) {
        if (base->sType ==
            VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO) {

            auto* info =
                reinterpret_cast<VkLayerInstanceCreateInfo*>(
                    const_cast<VkBaseInStructure*>(base)
                );

            if (info->function == VK_LAYER_LINK_INFO)
                return info;
        }

        base = base->pNext;
    }

    return nullptr;
}


static VkLayerDeviceCreateInfo*
find_device_chain(
    const VkDeviceCreateInfo* create_info
)
{
    auto* base =
        reinterpret_cast<const VkBaseInStructure*>(
            create_info->pNext
        );

    while (base) {
        if (base->sType ==
            VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO) {

            auto* info =
                reinterpret_cast<VkLayerDeviceCreateInfo*>(
                    const_cast<VkBaseInStructure*>(base)
                );

            if (info->function == VK_LAYER_LINK_INFO)
                return info;
        }

        base = base->pNext;
    }

    return nullptr;
}


static void
destroy_present_resources_locked(
    SwapchainState& state,
    const DeviceDispatch& d
)
{
    if (!state.fences.empty() && d.wait_for_fences) {
        for (VkFence fence : state.fences) {
            if (fence) {
                d.wait_for_fences(
                    state.device,
                    1,
                    &fence,
                    VK_TRUE,
                    UINT64_MAX
                );
            }
        }
    }

    destroy_blur_resources_locked(state, d);

    for (VkSemaphore semaphore : state.semaphores) {
        if (semaphore && d.destroy_semaphore) {
            d.destroy_semaphore(
                state.device,
                semaphore,
                nullptr
            );
        }
    }

    for (VkFence fence : state.fences) {
        if (fence && d.destroy_fence) {
            d.destroy_fence(
                state.device,
                fence,
                nullptr
            );
        }
    }

    if (state.command_pool && d.destroy_command_pool) {
        d.destroy_command_pool(
            state.device,
            state.command_pool,
            nullptr
        );
    }

    state.command_buffers.clear();
    state.semaphores.clear();
    state.fences.clear();

    state.command_pool = VK_NULL_HANDLE;
    state.queue_family = UINT32_MAX;
    state.present_resources_ready = false;
}


static void
destroy_swapchain_state(
    const std::shared_ptr<SwapchainState>& state,
    const DeviceDispatch& d
)
{
    if (!state)
        return;

    std::lock_guard<std::mutex> lock(state->mutex);

    destroy_present_resources_locked(*state, d);

    for (VkImageView view : state->views) {
        if (view && d.destroy_image_view) {
            d.destroy_image_view(
                state->device,
                view,
                nullptr
            );
        }
    }

    state->views.clear();
    state->images.clear();
}


static bool
init_present_resources_locked(
    SwapchainState& state,
    const DeviceDispatch& d,
    uint32_t queue_family
)
{
    if (state.present_resources_ready) {
        return state.queue_family == queue_family;
    }

    if (!state.overlay_supported)
        return false;

    if (state.images.empty())
        return false;

    VkCommandPoolCreateInfo pool_info{};
    pool_info.sType =
        VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;

    pool_info.flags =
        VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;

    pool_info.queueFamilyIndex = queue_family;

    if (d.create_command_pool(
            state.device,
            &pool_info,
            nullptr,
            &state.command_pool
        ) != VK_SUCCESS) {

        log_line(
            "[LWCompat HUD] vkCreateCommandPool failed"
        );

        return false;
    }

    state.command_buffers.resize(state.images.size());

    VkCommandBufferAllocateInfo alloc_info{};
    alloc_info.sType =
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;

    alloc_info.commandPool = state.command_pool;
    alloc_info.level =
        VK_COMMAND_BUFFER_LEVEL_PRIMARY;

    alloc_info.commandBufferCount =
        static_cast<uint32_t>(
            state.command_buffers.size()
        );

    if (d.allocate_command_buffers(
            state.device,
            &alloc_info,
            state.command_buffers.data()
        ) != VK_SUCCESS) {

        log_line(
            "[LWCompat HUD] vkAllocateCommandBuffers failed"
        );

        destroy_present_resources_locked(state, d);
        return false;
    }

    const size_t count = state.images.size();

    state.semaphores.resize(
        count,
        VK_NULL_HANDLE
    );

    state.fences.resize(
        count,
        VK_NULL_HANDLE
    );

    for (size_t i = 0; i < count; ++i) {
        VkSemaphoreCreateInfo sem_info{};
        sem_info.sType =
            VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;

        if (d.create_semaphore(
                state.device,
                &sem_info,
                nullptr,
                &state.semaphores[i]
            ) != VK_SUCCESS) {

            log_line(
                "[LWCompat HUD] vkCreateSemaphore failed"
            );

            destroy_present_resources_locked(state, d);
            return false;
        }

        VkFenceCreateInfo fence_info{};
        fence_info.sType =
            VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;

        fence_info.flags =
            VK_FENCE_CREATE_SIGNALED_BIT;

        if (d.create_fence(
                state.device,
                &fence_info,
                nullptr,
                &state.fences[i]
            ) != VK_SUCCESS) {

            log_line(
                "[LWCompat HUD] vkCreateFence failed"
            );

            destroy_present_resources_locked(state, d);
            return false;
        }
    }

    state.queue_family = queue_family;

    if (state.blur_supported &&
        !init_blur_resources_locked(state, d)) {

        log_line(
            "[LWCompat HUD] blur unavailable; using glass fallback"
        );
    }

    state.present_resources_ready = true;

    log_line(
        "[LWCompat HUD] present resources ready: images=%zu queueFamily=%u",
        count,
        queue_family
    );

    return true;
}


extern "C" {

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(
    VkInstance instance,
    const char* name
);

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetDeviceProcAddr(
    VkDevice device,
    const char* name
);

VKAPI_ATTR VkResult VKAPI_CALL
vkCreateSwapchainKHR(
    VkDevice device,
    const VkSwapchainCreateInfoKHR* create_info,
    const VkAllocationCallbacks* allocator,
    VkSwapchainKHR* swapchain
);

VKAPI_ATTR void VKAPI_CALL
vkDestroySwapchainKHR(
    VkDevice device,
    VkSwapchainKHR swapchain,
    const VkAllocationCallbacks* allocator
);

VKAPI_ATTR VkResult VKAPI_CALL
vkQueuePresentKHR(
    VkQueue queue,
    const VkPresentInfoKHR* present_info
);


VKAPI_ATTR VkResult VKAPI_CALL
vkCreateInstance(
    const VkInstanceCreateInfo* create_info,
    const VkAllocationCallbacks* allocator,
    VkInstance* instance
)
{
    auto* chain = find_instance_chain(create_info);

    if (!chain || !chain->u.pLayerInfo)
        return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr next_gipa =
        chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;

    auto next_create =
        reinterpret_cast<PFN_vkCreateInstance>(
            next_gipa(
                VK_NULL_HANDLE,
                "vkCreateInstance"
            )
        );

    if (!next_create)
        return VK_ERROR_INITIALIZATION_FAILED;

    chain->u.pLayerInfo =
        chain->u.pLayerInfo->pNext;

    VkResult result =
        next_create(
            create_info,
            allocator,
            instance
        );

    if (result != VK_SUCCESS)
        return result;

    InstanceDispatch table;
    table.instance = *instance;
    table.gipa = next_gipa;

    table.destroy_instance =
        reinterpret_cast<PFN_vkDestroyInstance>(
            next_gipa(
                *instance,
                "vkDestroyInstance"
            )
        );

    table.enumerate_physical_devices =
        reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(
            next_gipa(
                *instance,
                "vkEnumeratePhysicalDevices"
            )
        );

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        g_instances[*instance] = table;

        g_instance_keys[
            dispatch_key(*instance)
        ] = *instance;
    }

    log_line(
        "[LWCompat HUD] vkCreateInstance"
    );

    return result;
}


VKAPI_ATTR void VKAPI_CALL
vkDestroyInstance(
    VkInstance instance,
    const VkAllocationCallbacks* allocator
)
{
    PFN_vkDestroyInstance next = nullptr;

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        auto it = g_instances.find(instance);

        if (it != g_instances.end())
            next = it->second.destroy_instance;

        g_instance_keys.erase(
            dispatch_key(instance)
        );

        for (auto it2 = g_phys_instances.begin();
             it2 != g_phys_instances.end();) {

            if (it2->second == instance)
                it2 = g_phys_instances.erase(it2);
            else
                ++it2;
        }

        g_instances.erase(instance);
    }

    if (next)
        next(instance, allocator);
}


VKAPI_ATTR VkResult VKAPI_CALL
vkEnumeratePhysicalDevices(
    VkInstance instance,
    uint32_t* count,
    VkPhysicalDevice* devices
)
{
    PFN_vkEnumeratePhysicalDevices next = nullptr;

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        auto it = g_instances.find(instance);

        if (it != g_instances.end())
            next = it->second.enumerate_physical_devices;
    }

    if (!next)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkResult result =
        next(instance, count, devices);

    if (devices &&
        (result == VK_SUCCESS ||
         result == VK_INCOMPLETE)) {

        std::lock_guard<std::mutex> lock(g_mutex);

        for (uint32_t i = 0; i < *count; ++i)
            g_phys_instances[devices[i]] = instance;
    }

    return result;
}


VKAPI_ATTR VkResult VKAPI_CALL
vkCreateDevice(
    VkPhysicalDevice physical_device,
    const VkDeviceCreateInfo* create_info,
    const VkAllocationCallbacks* allocator,
    VkDevice* device
)
{
    auto* chain = find_device_chain(create_info);

    if (!chain || !chain->u.pLayerInfo)
        return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr next_gipa =
        chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;

    PFN_vkGetDeviceProcAddr next_gdpa =
        chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;

    VkInstance instance = VK_NULL_HANDLE;

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        auto it =
            g_phys_instances.find(physical_device);

        if (it != g_phys_instances.end()) {
            instance = it->second;
        } else {
            auto key_it =
                g_instance_keys.find(
                    dispatch_key(physical_device)
                );

            if (key_it != g_instance_keys.end())
                instance = key_it->second;
        }
    }

    if (!instance)
        return VK_ERROR_INITIALIZATION_FAILED;

    auto next_create =
        reinterpret_cast<PFN_vkCreateDevice>(
            next_gipa(
                instance,
                "vkCreateDevice"
            )
        );

    if (!next_create)
        return VK_ERROR_INITIALIZATION_FAILED;

    chain->u.pLayerInfo =
        chain->u.pLayerInfo->pNext;

    VkResult result =
        next_create(
            physical_device,
            create_info,
            allocator,
            device
        );

    if (result != VK_SUCCESS)
        return result;

    DeviceDispatch d;

    d.device = *device;
    d.physical_device = physical_device;
    d.instance = instance;
    d.gipa = next_gipa;
    d.gdpa = next_gdpa;

#define LOAD_DEVICE_FN(member, name) \
    d.member = reinterpret_cast<PFN_##name>( \
        next_gdpa(*device, #name) \
    )

    LOAD_DEVICE_FN(
        destroy_device,
        vkDestroyDevice
    );

    LOAD_DEVICE_FN(
        get_device_queue,
        vkGetDeviceQueue
    );

    LOAD_DEVICE_FN(
        get_device_queue2,
        vkGetDeviceQueue2
    );

    LOAD_DEVICE_FN(
        queue_present,
        vkQueuePresentKHR
    );

    LOAD_DEVICE_FN(
        queue_submit,
        vkQueueSubmit
    );

    LOAD_DEVICE_FN(
        create_swapchain,
        vkCreateSwapchainKHR
    );

    LOAD_DEVICE_FN(
        destroy_swapchain,
        vkDestroySwapchainKHR
    );

    LOAD_DEVICE_FN(
        get_swapchain_images,
        vkGetSwapchainImagesKHR
    );

    LOAD_DEVICE_FN(
        create_image_view,
        vkCreateImageView
    );

    LOAD_DEVICE_FN(
        destroy_image_view,
        vkDestroyImageView
    );

    LOAD_DEVICE_FN(
        create_image,
        vkCreateImage
    );

    LOAD_DEVICE_FN(
        destroy_image,
        vkDestroyImage
    );

    LOAD_DEVICE_FN(
        get_image_memory_requirements,
        vkGetImageMemoryRequirements
    );

    LOAD_DEVICE_FN(
        allocate_memory,
        vkAllocateMemory
    );

    LOAD_DEVICE_FN(
        free_memory,
        vkFreeMemory
    );

    LOAD_DEVICE_FN(
        bind_image_memory,
        vkBindImageMemory
    );

    LOAD_DEVICE_FN(
        create_sampler,
        vkCreateSampler
    );

    LOAD_DEVICE_FN(
        destroy_sampler,
        vkDestroySampler
    );

    LOAD_DEVICE_FN(
        create_command_pool,
        vkCreateCommandPool
    );

    LOAD_DEVICE_FN(
        destroy_command_pool,
        vkDestroyCommandPool
    );

    LOAD_DEVICE_FN(
        allocate_command_buffers,
        vkAllocateCommandBuffers
    );

    LOAD_DEVICE_FN(
        create_semaphore,
        vkCreateSemaphore
    );

    LOAD_DEVICE_FN(
        destroy_semaphore,
        vkDestroySemaphore
    );

    LOAD_DEVICE_FN(
        create_fence,
        vkCreateFence
    );

    LOAD_DEVICE_FN(
        destroy_fence,
        vkDestroyFence
    );

    LOAD_DEVICE_FN(
        wait_for_fences,
        vkWaitForFences
    );

    LOAD_DEVICE_FN(
        reset_fences,
        vkResetFences
    );

    LOAD_DEVICE_FN(
        reset_command_buffer,
        vkResetCommandBuffer
    );

    LOAD_DEVICE_FN(
        begin_command_buffer,
        vkBeginCommandBuffer
    );

    LOAD_DEVICE_FN(
        end_command_buffer,
        vkEndCommandBuffer
    );

    LOAD_DEVICE_FN(
        cmd_pipeline_barrier,
        vkCmdPipelineBarrier
    );

    LOAD_DEVICE_FN(
        cmd_blit_image,
        vkCmdBlitImage
    );

    LOAD_DEVICE_FN(
        cmd_begin_rendering,
        vkCmdBeginRendering
    );

    LOAD_DEVICE_FN(
        cmd_end_rendering,
        vkCmdEndRendering
    );

    LOAD_DEVICE_FN(
        cmd_clear_attachments,
        vkCmdClearAttachments
    );

#undef LOAD_DEVICE_FN

    d.get_surface_capabilities =
        reinterpret_cast<
            PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR
        >(
            next_gipa(
                instance,
                "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"
            )
        );

    d.get_memory_properties =
        reinterpret_cast<
            PFN_vkGetPhysicalDeviceMemoryProperties
        >(
            next_gipa(
                instance,
                "vkGetPhysicalDeviceMemoryProperties"
            )
        );

    d.get_format_properties =
        reinterpret_cast<
            PFN_vkGetPhysicalDeviceFormatProperties
        >(
            next_gipa(
                instance,
                "vkGetPhysicalDeviceFormatProperties"
            )
        );

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        g_devices[*device] = d;

        g_device_keys[
            dispatch_key(*device)
        ] = *device;
    }

    log_line(
        "[LWCompat HUD] vkCreateDevice"
    );

    return result;
}


VKAPI_ATTR void VKAPI_CALL
vkDestroyDevice(
    VkDevice device,
    const VkAllocationCallbacks* allocator
)
{
    DeviceDispatch d;

    if (!get_device_dispatch(device, d))
        return;

    std::vector<
        std::shared_ptr<SwapchainState>
    > owned_swapchains;

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        for (auto it = g_swapchains.begin();
             it != g_swapchains.end();) {

            if (it->second->device == device) {
                owned_swapchains.push_back(
                    it->second
                );

                it = g_swapchains.erase(it);
            } else {
                ++it;
            }
        }

        for (auto it = g_queues.begin();
             it != g_queues.end();) {

            if (it->second.device == device)
                it = g_queues.erase(it);
            else
                ++it;
        }

        g_device_keys.erase(
            dispatch_key(device)
        );

        g_devices.erase(device);
    }

    for (auto& state : owned_swapchains)
        destroy_swapchain_state(state, d);

    lw_hud_shutdown(device);

    if (d.destroy_device)
        d.destroy_device(device, allocator);
}


VKAPI_ATTR void VKAPI_CALL
vkGetDeviceQueue(
    VkDevice device,
    uint32_t family,
    uint32_t index,
    VkQueue* queue
)
{
    DeviceDispatch d;

    if (!get_device_dispatch(device, d))
        return;

    if (!d.get_device_queue)
        return;

    d.get_device_queue(
        device,
        family,
        index,
        queue
    );

    if (queue && *queue) {
        std::lock_guard<std::mutex> lock(g_mutex);

        g_queues[*queue] = {
            device,
            family
        };
    }
}


VKAPI_ATTR void VKAPI_CALL
vkGetDeviceQueue2(
    VkDevice device,
    const VkDeviceQueueInfo2* queue_info,
    VkQueue* queue
)
{
    DeviceDispatch d;

    if (!get_device_dispatch(device, d))
        return;

    if (!d.get_device_queue2)
        return;

    d.get_device_queue2(
        device,
        queue_info,
        queue
    );

    if (queue && *queue) {
        std::lock_guard<std::mutex> lock(g_mutex);

        g_queues[*queue] = {
            device,
            queue_info->queueFamilyIndex
        };
    }
}


VKAPI_ATTR VkResult VKAPI_CALL
vkCreateSwapchainKHR(
    VkDevice device,
    const VkSwapchainCreateInfoKHR* create_info,
    const VkAllocationCallbacks* allocator,
    VkSwapchainKHR* swapchain
)
{
    DeviceDispatch d;

    if (!get_device_dispatch(device, d))
        return VK_ERROR_INITIALIZATION_FAILED;

    if (!d.create_swapchain)
        return VK_ERROR_EXTENSION_NOT_PRESENT;

    VkSwapchainCreateInfoKHR local =
        *create_info;

    bool color_supported =
        (local.imageUsage &
         VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) != 0;

    if (!color_supported &&
        d.get_surface_capabilities) {

        VkSurfaceCapabilitiesKHR caps{};

        VkResult caps_result =
            d.get_surface_capabilities(
                d.physical_device,
                local.surface,
                &caps
            );

        if (caps_result == VK_SUCCESS &&
            (caps.supportedUsageFlags &
             VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) {

            local.imageUsage |=
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

            color_supported = true;
        }
    }

    bool transfer_src_supported =
        (local.imageUsage &
         VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0;

    if (!transfer_src_supported &&
        d.get_surface_capabilities) {

        VkSurfaceCapabilitiesKHR caps{};

        VkResult caps_result =
            d.get_surface_capabilities(
                d.physical_device,
                local.surface,
                &caps
            );

        if (caps_result == VK_SUCCESS &&
            (caps.supportedUsageFlags &
             VK_IMAGE_USAGE_TRANSFER_SRC_BIT)) {

            local.imageUsage |=
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT;

            transfer_src_supported = true;
        }
    }

    VkResult result =
        d.create_swapchain(
            device,
            &local,
            allocator,
            swapchain
        );

    if (result != VK_SUCCESS)
        return result;

    auto state =
        std::make_shared<SwapchainState>();

    state->device = device;
    state->swapchain = *swapchain;
    state->format = local.imageFormat;
    state->extent = local.imageExtent;
    state->layers =
        std::max(
            1u,
            local.imageArrayLayers
        );

    state->overlay_supported =
        color_supported &&
        d.create_image_view &&
        d.destroy_image_view &&
        d.create_command_pool &&
        d.destroy_command_pool &&
        d.allocate_command_buffers &&
        d.create_semaphore &&
        d.destroy_semaphore &&
        d.create_fence &&
        d.destroy_fence &&
        d.wait_for_fences &&
        d.reset_fences &&
        d.reset_command_buffer &&
        d.begin_command_buffer &&
        d.end_command_buffer &&
        d.cmd_pipeline_barrier &&
        d.cmd_begin_rendering &&
        d.cmd_end_rendering &&
        d.queue_submit;

    bool format_blur_supported = false;

    if (d.get_format_properties) {
        VkFormatProperties format_props{};

        d.get_format_properties(
            d.physical_device,
            state->format,
            &format_props
        );

        const VkFormatFeatureFlags needed =
            VK_FORMAT_FEATURE_BLIT_SRC_BIT |
            VK_FORMAT_FEATURE_BLIT_DST_BIT |
            VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
            VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;

        format_blur_supported =
            (format_props.optimalTilingFeatures & needed) == needed;
    }

    state->blur_supported =
        state->overlay_supported &&
        transfer_src_supported &&
        state->layers == 1 &&
        format_blur_supported &&
        d.create_image &&
        d.destroy_image &&
        d.get_image_memory_requirements &&
        d.allocate_memory &&
        d.free_memory &&
        d.bind_image_memory &&
        d.create_sampler &&
        d.destroy_sampler &&
        d.cmd_blit_image &&
        d.get_memory_properties;

    if (state->overlay_supported) {
        uint32_t count = 0;

        if (d.get_swapchain_images(
                device,
                *swapchain,
                &count,
                nullptr
            ) == VK_SUCCESS &&
            count > 0) {

            state->images.resize(count);

            VkResult image_result =
                d.get_swapchain_images(
                    device,
                    *swapchain,
                    &count,
                    state->images.data()
                );

            if (image_result != VK_SUCCESS &&
                image_result != VK_INCOMPLETE) {

                state->images.clear();
                state->overlay_supported = false;
            }
        } else {
            state->overlay_supported = false;
        }
    }

    if (state->overlay_supported) {
        state->views.resize(
            state->images.size(),
            VK_NULL_HANDLE
        );

        for (size_t i = 0;
             i < state->images.size();
             ++i) {

            VkImageViewCreateInfo view_info{};
            view_info.sType =
                VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;

            view_info.image =
                state->images[i];

            view_info.viewType =
                state->layers > 1
                    ? VK_IMAGE_VIEW_TYPE_2D_ARRAY
                    : VK_IMAGE_VIEW_TYPE_2D;

            view_info.format =
                state->format;

            view_info.components = {
                VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY
            };

            view_info.subresourceRange.aspectMask =
                VK_IMAGE_ASPECT_COLOR_BIT;

            view_info.subresourceRange.baseMipLevel = 0;
            view_info.subresourceRange.levelCount = 1;

            view_info.subresourceRange.baseArrayLayer = 0;
            view_info.subresourceRange.layerCount =
                state->layers;

            VkResult view_result =
                d.create_image_view(
                    device,
                    &view_info,
                    nullptr,
                    &state->views[i]
                );

            if (view_result != VK_SUCCESS) {
                state->overlay_supported = false;
                break;
            }
        }
    }

    if (!state->overlay_supported) {
        for (VkImageView view : state->views) {
            if (view && d.destroy_image_view) {
                d.destroy_image_view(
                    device,
                    view,
                    nullptr
                );
            }
        }

        state->views.clear();
    }

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        g_swapchains[*swapchain] = state;
    }

    log_line(
        "[LWCompat HUD] swapchain: %ux%u format=%d usage=0x%x overlay=%s blur=%s",
        state->extent.width,
        state->extent.height,
        static_cast<int>(state->format),
        local.imageUsage,
        state->overlay_supported ? "YES" : "NO",
        state->blur_supported ? "YES" : "NO"
    );

    return VK_SUCCESS;
}


VKAPI_ATTR void VKAPI_CALL
vkDestroySwapchainKHR(
    VkDevice device,
    VkSwapchainKHR swapchain,
    const VkAllocationCallbacks* allocator
)
{
    DeviceDispatch d;

    if (!get_device_dispatch(device, d))
        return;

    std::shared_ptr<SwapchainState> state;

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        auto it =
            g_swapchains.find(swapchain);

        if (it != g_swapchains.end()) {
            state = it->second;
            g_swapchains.erase(it);
        }
    }

    if (state)
        destroy_swapchain_state(state, d);

    if (d.destroy_swapchain) {
        d.destroy_swapchain(
            device,
            swapchain,
            allocator
        );
    }
}


VKAPI_ATTR VkResult VKAPI_CALL
vkQueuePresentKHR(
    VkQueue queue,
    const VkPresentInfoKHR* present_info
)
{
    QueueInfo queue_info{};

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        auto it = g_queues.find(queue);

        if (it != g_queues.end()) {
            queue_info = it->second;
        } else {
            auto key =
                g_device_keys.find(
                    dispatch_key(queue)
                );

            if (key != g_device_keys.end()) {
                queue_info.device =
                    key->second;
            }
        }
    }

    if (!queue_info.device)
        return VK_ERROR_INITIALIZATION_FAILED;

    DeviceDispatch d;

    if (!get_device_dispatch(
            queue_info.device,
            d
        )) {

        return VK_ERROR_INITIALIZATION_FAILED;
    }

    if (!d.queue_present)
        return VK_ERROR_EXTENSION_NOT_PRESENT;

    const uint64_t frame =
        ++g_present_count;

    if (!present_info ||
        present_info->swapchainCount != 1 ||
        queue_info.family == UINT32_MAX) {

        return d.queue_present(
            queue,
            present_info
        );
    }

    VkSwapchainKHR swapchain =
        present_info->pSwapchains[0];

    uint32_t image_index =
        present_info->pImageIndices[0];

    std::shared_ptr<SwapchainState> state;

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        auto it =
            g_swapchains.find(swapchain);

        if (it != g_swapchains.end())
            state = it->second;
    }

    if (!state ||
        !state->overlay_supported) {

        return d.queue_present(
            queue,
            present_info
        );
    }

    std::lock_guard<std::mutex>
        state_lock(state->mutex);

    if (!init_present_resources_locked(
            *state,
            d,
            queue_info.family
        )) {

        return d.queue_present(
            queue,
            present_info
        );
    }

    if (image_index >=
        state->images.size()) {

        return d.queue_present(
            queue,
            present_info
        );
    }

    const bool hud_ready =
        lw_hud_ensure(
            d.instance,
            d.physical_device,
            state->device,
            queue,
            queue_info.family,
            state->format,
            static_cast<uint32_t>(
                state->images.size()
            ),
            d.gipa,
            d.gdpa
        );

    if (!hud_ready) {
        return d.queue_present(
            queue,
            present_info
        );
    }

    VkFence fence =
        state->fences[image_index];

    VkResult wait_result =
        d.wait_for_fences(
            state->device,
            1,
            &fence,
            VK_TRUE,
            UINT64_MAX
        );

    if (wait_result != VK_SUCCESS) {
        return d.queue_present(
            queue,
            present_info
        );
    }

    d.reset_fences(
        state->device,
        1,
        &fence
    );

    VkCommandBuffer cmd =
        state->command_buffers[image_index];

    d.reset_command_buffer(
        cmd,
        0
    );

    VkCommandBufferBeginInfo begin_info{};
    begin_info.sType =
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;

    begin_info.flags =
        VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    if (d.begin_command_buffer(
            cmd,
            &begin_info
        ) != VK_SUCCESS) {

        return d.queue_present(
            queue,
            present_info
        );
    }

    VkImageSubresourceRange swapchain_range{};
    swapchain_range.aspectMask =
        VK_IMAGE_ASPECT_COLOR_BIT;

    swapchain_range.baseMipLevel = 0;
    swapchain_range.levelCount = 1;
    swapchain_range.baseArrayLayer = 0;
    swapchain_range.layerCount =
        state->layers;

    bool blur_ready = false;

    if (state->blur_supported &&
        state->blur_image != VK_NULL_HANDLE &&
        state->blur_view != VK_NULL_HANDLE &&
        state->blur_sampler != VK_NULL_HANDLE &&
        lw_hud_set_blur_texture(
            state->blur_sampler,
            state->blur_view
        )) {

        VkImageMemoryBarrier begin_barriers[2]{};

        begin_barriers[0].sType =
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;

        begin_barriers[0].srcAccessMask = 0;
        begin_barriers[0].dstAccessMask =
            VK_ACCESS_TRANSFER_READ_BIT;

        begin_barriers[0].oldLayout =
            VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        begin_barriers[0].newLayout =
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;

        begin_barriers[0].srcQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        begin_barriers[0].dstQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        begin_barriers[0].image =
            state->images[image_index];

        begin_barriers[0].subresourceRange =
            swapchain_range;

        begin_barriers[1].sType =
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;

        begin_barriers[1].srcAccessMask =
            state->blur_layout_initialized
                ? VK_ACCESS_SHADER_READ_BIT
                : 0;

        begin_barriers[1].dstAccessMask =
            VK_ACCESS_TRANSFER_WRITE_BIT;

        begin_barriers[1].oldLayout =
            state->blur_layout_initialized
                ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                : VK_IMAGE_LAYOUT_UNDEFINED;

        begin_barriers[1].newLayout =
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;

        begin_barriers[1].srcQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        begin_barriers[1].dstQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        begin_barriers[1].image =
            state->blur_image;

        begin_barriers[1].subresourceRange.aspectMask =
            VK_IMAGE_ASPECT_COLOR_BIT;

        begin_barriers[1].subresourceRange.baseMipLevel = 0;
        begin_barriers[1].subresourceRange.levelCount = 1;
        begin_barriers[1].subresourceRange.baseArrayLayer = 0;
        begin_barriers[1].subresourceRange.layerCount = 1;

        d.cmd_pipeline_barrier(
            cmd,
            VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            nullptr,
            0,
            nullptr,
            2,
            begin_barriers
        );

        VkOffset2D hud_offset{};
        VkExtent2D hud_size{};

        lw_hud_get_rect(
            state->extent,
            &hud_offset,
            &hud_size
        );

        VkImageBlit blit{};

        blit.srcSubresource.aspectMask =
            VK_IMAGE_ASPECT_COLOR_BIT;

        blit.srcSubresource.mipLevel = 0;
        blit.srcSubresource.baseArrayLayer = 0;
        blit.srcSubresource.layerCount = 1;

        blit.srcOffsets[0] = {
            hud_offset.x,
            hud_offset.y,
            0
        };

        blit.srcOffsets[1] = {
            hud_offset.x +
                static_cast<int32_t>(hud_size.width),
            hud_offset.y +
                static_cast<int32_t>(hud_size.height),
            1
        };

        blit.dstSubresource.aspectMask =
            VK_IMAGE_ASPECT_COLOR_BIT;

        blit.dstSubresource.mipLevel = 0;
        blit.dstSubresource.baseArrayLayer = 0;
        blit.dstSubresource.layerCount = 1;

        blit.dstOffsets[0] = {0, 0, 0};

        blit.dstOffsets[1] = {
            static_cast<int32_t>(
                state->blur_extent.width
            ),
            static_cast<int32_t>(
                state->blur_extent.height
            ),
            1
        };

        d.cmd_blit_image(
            cmd,
            state->images[image_index],
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            state->blur_image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &blit,
            VK_FILTER_LINEAR
        );

        VkImageMemoryBarrier end_barriers[2]{};

        end_barriers[0].sType =
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;

        end_barriers[0].srcAccessMask =
            VK_ACCESS_TRANSFER_READ_BIT;

        end_barriers[0].dstAccessMask =
            VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        end_barriers[0].oldLayout =
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;

        end_barriers[0].newLayout =
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        end_barriers[0].srcQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        end_barriers[0].dstQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        end_barriers[0].image =
            state->images[image_index];

        end_barriers[0].subresourceRange =
            swapchain_range;

        end_barriers[1].sType =
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;

        end_barriers[1].srcAccessMask =
            VK_ACCESS_TRANSFER_WRITE_BIT;

        end_barriers[1].dstAccessMask =
            VK_ACCESS_SHADER_READ_BIT;

        end_barriers[1].oldLayout =
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;

        end_barriers[1].newLayout =
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        end_barriers[1].srcQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        end_barriers[1].dstQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        end_barriers[1].image =
            state->blur_image;

        end_barriers[1].subresourceRange =
            begin_barriers[1].subresourceRange;

        d.cmd_pipeline_barrier(
            cmd,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            nullptr,
            0,
            nullptr,
            2,
            end_barriers
        );

        state->blur_layout_initialized = true;
        blur_ready = true;
    } else {
        VkImageMemoryBarrier to_color{};
        to_color.sType =
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;

        to_color.srcAccessMask = 0;
        to_color.dstAccessMask =
            VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        to_color.oldLayout =
            VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        to_color.newLayout =
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        to_color.srcQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        to_color.dstQueueFamilyIndex =
            VK_QUEUE_FAMILY_IGNORED;

        to_color.image =
            state->images[image_index];

        to_color.subresourceRange =
            swapchain_range;

        d.cmd_pipeline_barrier(
            cmd,
            VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,
            0,
            nullptr,
            0,
            nullptr,
            1,
            &to_color
        );
    }

    VkRenderingAttachmentInfo attachment{};
    attachment.sType =
        VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;

    attachment.imageView =
        state->views[image_index];

    attachment.imageLayout =
        VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    attachment.resolveMode =
        VK_RESOLVE_MODE_NONE;

    attachment.loadOp =
        VK_ATTACHMENT_LOAD_OP_LOAD;

    attachment.storeOp =
        VK_ATTACHMENT_STORE_OP_STORE;

    VkRenderingInfo rendering{};
    rendering.sType =
        VK_STRUCTURE_TYPE_RENDERING_INFO;

    rendering.renderArea.offset = {
        0,
        0
    };

    rendering.renderArea.extent =
        state->extent;

    rendering.layerCount =
        state->layers;

    rendering.colorAttachmentCount = 1;
    rendering.pColorAttachments =
        &attachment;

    d.cmd_begin_rendering(
        cmd,
        &rendering
    );

    lw_hud_render(
        cmd,
        state->extent,
        blur_ready
    );

    d.cmd_end_rendering(cmd);

    VkImageMemoryBarrier to_present{};
    to_present.sType =
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;

    to_present.srcAccessMask =
        VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    to_present.dstAccessMask = 0;

    to_present.oldLayout =
        VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    to_present.newLayout =
        VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    to_present.srcQueueFamilyIndex =
        VK_QUEUE_FAMILY_IGNORED;

    to_present.dstQueueFamilyIndex =
        VK_QUEUE_FAMILY_IGNORED;

    to_present.image =
        state->images[image_index];

    to_present.subresourceRange =
        swapchain_range;

    d.cmd_pipeline_barrier(
        cmd,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0,
        0,
        nullptr,
        0,
        nullptr,
        1,
        &to_present
    );

    if (d.end_command_buffer(cmd)
        != VK_SUCCESS) {

        return d.queue_present(
            queue,
            present_info
        );
    }

    std::vector<VkPipelineStageFlags>
        wait_stages(
            present_info->waitSemaphoreCount,
            VK_PIPELINE_STAGE_ALL_COMMANDS_BIT
        );

    VkSemaphore overlay_semaphore =
        state->semaphores[image_index];

    VkSubmitInfo submit{};
    submit.sType =
        VK_STRUCTURE_TYPE_SUBMIT_INFO;

    submit.waitSemaphoreCount =
        present_info->waitSemaphoreCount;

    submit.pWaitSemaphores =
        present_info->pWaitSemaphores;

    submit.pWaitDstStageMask =
        wait_stages.empty()
            ? nullptr
            : wait_stages.data();

    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &cmd;

    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores =
        &overlay_semaphore;

    VkResult submit_result =
        d.queue_submit(
            queue,
            1,
            &submit,
            fence
        );

    if (submit_result != VK_SUCCESS) {
        log_line(
            "[LWCompat HUD] overlay submit failed: %d",
            submit_result
        );

        d.destroy_fence(
            state->device,
            fence,
            nullptr
        );

        VkFenceCreateInfo fence_info{};
        fence_info.sType =
            VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;

        fence_info.flags =
            VK_FENCE_CREATE_SIGNALED_BIT;

        d.create_fence(
            state->device,
            &fence_info,
            nullptr,
            &state->fences[image_index]
        );

        return d.queue_present(
            queue,
            present_info
        );
    }

    VkPresentInfoKHR modified =
        *present_info;

    modified.waitSemaphoreCount = 1;
    modified.pWaitSemaphores =
        &overlay_semaphore;

    if (frame == 1 ||
        (frame % 120) == 0) {

        log_line(
            "[LWCompat HUD] custom present frame=%llu image=%u",
            static_cast<unsigned long long>(
                frame
            ),
            image_index
        );
    }

    return d.queue_present(
        queue,
        &modified
    );
}


VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetDeviceProcAddr(
    VkDevice device,
    const char* name
)
{
    if (!name)
        return nullptr;

#define HOOK(fn) \
    if (std::strcmp(name, #fn) == 0) \
        return reinterpret_cast< \
            PFN_vkVoidFunction \
        >(fn)

    HOOK(vkGetDeviceProcAddr);
    HOOK(vkDestroyDevice);

    HOOK(vkGetDeviceQueue);
    HOOK(vkGetDeviceQueue2);

    HOOK(vkCreateSwapchainKHR);
    HOOK(vkDestroySwapchainKHR);
    HOOK(vkQueuePresentKHR);

#undef HOOK

    DeviceDispatch d;

    if (!get_device_dispatch(device, d))
        return nullptr;

    if (!d.gdpa)
        return nullptr;

    return d.gdpa(
        device,
        name
    );
}


VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(
    VkInstance instance,
    const char* name
)
{
    if (!name)
        return nullptr;

#define HOOK(fn) \
    if (std::strcmp(name, #fn) == 0) \
        return reinterpret_cast< \
            PFN_vkVoidFunction \
        >(fn)

    HOOK(vkGetInstanceProcAddr);
    HOOK(vkGetDeviceProcAddr);

    HOOK(vkCreateInstance);
    HOOK(vkDestroyInstance);
    HOOK(vkEnumeratePhysicalDevices);
    HOOK(vkCreateDevice);

    HOOK(vkCreateSwapchainKHR);
    HOOK(vkDestroySwapchainKHR);
    HOOK(vkQueuePresentKHR);

#undef HOOK

    if (!instance)
        return nullptr;

    PFN_vkGetInstanceProcAddr next = nullptr;

    {
        std::lock_guard<std::mutex> lock(g_mutex);

        auto it =
            g_instances.find(instance);

        if (it != g_instances.end())
            next = it->second.gipa;
    }

    if (!next)
        return nullptr;

    return next(
        instance,
        name
    );
}


VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateInstanceLayerProperties(
    uint32_t* count,
    VkLayerProperties* properties
)
{
    if (!count)
        return VK_ERROR_INITIALIZATION_FAILED;

    if (!properties) {
        *count = 1;
        return VK_SUCCESS;
    }

    if (*count < 1) {
        *count = 1;
        return VK_INCOMPLETE;
    }

    VkLayerProperties prop{};

    std::strncpy(
        prop.layerName,
        LAYER_NAME,
        sizeof(prop.layerName) - 1
    );

    std::strncpy(
        prop.description,
        "LWCompat HUD development layer",
        sizeof(prop.description) - 1
    );

    prop.specVersion =
        VK_API_VERSION_1_4;

    prop.implementationVersion = 2;

    properties[0] = prop;
    *count = 1;

    return VK_SUCCESS;
}


VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateDeviceLayerProperties(
    VkPhysicalDevice,
    uint32_t* count,
    VkLayerProperties* properties
)
{
    return vkEnumerateInstanceLayerProperties(
        count,
        properties
    );
}


VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateInstanceExtensionProperties(
    const char* layer_name,
    uint32_t* count,
    VkExtensionProperties*
)
{
    if (!count)
        return VK_ERROR_INITIALIZATION_FAILED;

    if (layer_name &&
        std::strcmp(
            layer_name,
            LAYER_NAME
        ) != 0) {

        return VK_ERROR_LAYER_NOT_PRESENT;
    }

    *count = 0;
    return VK_SUCCESS;
}


VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateDeviceExtensionProperties(
    VkPhysicalDevice,
    const char* layer_name,
    uint32_t* count,
    VkExtensionProperties*
)
{
    if (!count)
        return VK_ERROR_INITIALIZATION_FAILED;

    if (layer_name &&
        std::strcmp(
            layer_name,
            LAYER_NAME
        ) != 0) {

        return VK_ERROR_LAYER_NOT_PRESENT;
    }

    *count = 0;
    return VK_SUCCESS;
}


VKAPI_ATTR VkResult VKAPI_CALL
vkNegotiateLoaderLayerInterfaceVersion(
    VkNegotiateLayerInterface* version
)
{
    if (!version)
        return VK_ERROR_INITIALIZATION_FAILED;

    if (version->loaderLayerInterfaceVersion >
        CURRENT_LOADER_LAYER_INTERFACE_VERSION) {

        version->loaderLayerInterfaceVersion =
            CURRENT_LOADER_LAYER_INTERFACE_VERSION;
    }

    version->pfnGetInstanceProcAddr =
        vkGetInstanceProcAddr;

    version->pfnGetDeviceProcAddr =
        vkGetDeviceProcAddr;

    version->pfnGetPhysicalDeviceProcAddr =
        nullptr;

    return VK_SUCCESS;
}

}
