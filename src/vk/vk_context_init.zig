const vk = @import("vulkan");
const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("glfw");
const builtin = @import("builtin");

const vk_dispatch = @import("vk_dispatch.zig");
const BaseDispatch = vk_dispatch.BaseDispatch;
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

const UploadContext = @import("UploadContext.zig");
const vk_enumerate = @import("vk_enumerate.zig");

const is_debug_mode: bool = builtin.mode == std.builtin.Mode.Debug;

const VkContext = @import("VkContext.zig");

pub fn initVkContext(allocator: Allocator, window: glfw.Window, app_name: [*:0]const u8) !VkContext {
    const vk_proc = @ptrCast(fn (instance: vk.Instance, procname: [*:0]const u8) callconv(.C) vk.PfnVoidFunction, glfw.getInstanceProcAddress);
    const base_dispatch = try BaseDispatch.load(vk_proc);

    const instance_layers = switch (is_debug_mode) {
        true => [_][*:0]const u8{ "VK_LAYER_KHRONOS_validation", "VK_LAYER_LUNARG_monitor" },
        false => [_][*:0]const u8{},
    };

    try ensureLayersSupported(allocator, base_dispatch, instance_layers[0..]);

    const platform_extensions: [][*:0]const u8 = try glfw.getRequiredInstanceExtensions();
    const debug_extensions = [_][*:0]const u8{vk.extension_info.ext_debug_utils.name};
    const instance_extensions: [][*:0]const u8 = try std.mem.concat(allocator, [*:0]const u8, &.{ platform_extensions, debug_extensions[0..] });
    defer allocator.free(instance_extensions);

    const instance = try initInstance(base_dispatch, app_name, instance_layers[0..], instance_extensions[0..]);
    const vki = try InstanceDispatch.load(instance, vk_proc);
    errdefer vki.destroyInstance(instance, null);

    const debug_messenger: ?vk.DebugUtilsMessengerEXT = switch (is_debug_mode) {
        true => try initDebugMessenger(instance, vki),
        false => null,
    };
    errdefer if (is_debug_mode) vki.destroyDebugUtilsMessengerEXT(instance, debug_messenger.?, null);

    const surface = try createSurface(instance, window);
    errdefer vki.destroyInstance(instance, null);

    const required_device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};
    const physical_device = try physical_device_selector.selectPhysicalDevice(instance, vki, surface, required_device_extensions[0..], allocator);

    //const min_uniform_buffer_offset_alignment = vki.getPhysicalDeviceProperties(physical_device).limits.min_uniform_buffer_offset_alignment;
    const pd_limits = vki.getPhysicalDeviceProperties(physical_device).limits;
    const min_uniform_buffer_offset_alignment = pd_limits.min_uniform_buffer_offset_alignment;
    const min_storage_buffer_offset_alignment = pd_limits.min_storage_buffer_offset_alignment;

    const queue_family_indices = try QueueFamilyIndices.find(allocator, vki, physical_device, surface);

    const device = try initDevice(vki, physical_device, required_device_extensions[0..], queue_family_indices);
    const vkd = try DeviceDispatch.load(device, vki.dispatch.vkGetDeviceProcAddr);

    const graphics_queue = initDeviceQueue(vkd, device, queue_family_indices.graphics);
    const present_queue = initDeviceQueue(vkd, device, queue_family_indices.present);

    var self = VkContext{
        .allocator = allocator,
        .vki = vki,
        .vkd = vkd,
        .instance = instance,
        .debug_messenger = debug_messenger,
        .surface = surface,
        .physical_device = physical_device,
        .device = device,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
        .upload_context = undefined,
        .physical_device_limits = .{
            .min_uniform_buffer_offset_alignment = min_uniform_buffer_offset_alignment,
            .min_storage_buffer_offset_alignment = min_storage_buffer_offset_alignment,
        },
    };

    const upload_context = try UploadContext.init(self, graphics_queue);
    self.upload_context = upload_context;

    return self;
}

pub fn deinitVkContext(self: VkContext) void {
    self.upload_context.deinit(self);

    self.vkd.destroyDevice(self.device, null);
    self.vki.destroySurfaceKHR(self.instance, self.surface, null);
    if (self.debug_messenger) |debug_messenger| self.vki.destroyDebugUtilsMessengerEXT(self.instance, debug_messenger, null);
    self.vki.destroyInstance(self.instance, null);
}

fn ensureLayersSupported(allocator: Allocator, vkb: BaseDispatch, required_layers: []const [*:0]const u8) !void {
    const available_layers = try vk_enumerate.enumerateInstanceLayerProperties(allocator, vkb);
    defer allocator.free(available_layers);

    var matches: usize = 0;
    for (required_layers) |required_layer| {
        for (available_layers) |available_layer| {
            const available_layer_slice: []const u8 = std.mem.span(@ptrCast([*:0]const u8, &available_layer.layer_name));
            const required_layer_slice: []const u8 = std.mem.span(@ptrCast([*:0]const u8, required_layer));

            if (std.mem.eql(u8, available_layer_slice, required_layer_slice)) {
                matches += 1;
            }
        }
    }

    std.log.info("this one passed", .{});

    if (matches != required_layers.len) {
        return error.VkRequiredLayersNotSupported;
    }
}

fn initInstance(vkb: BaseDispatch, app_name: [*:0]const u8, layers: []const [*:0]const u8, extensions: []const [*:0]const u8) !vk.Instance {
    const app_info = vk.ApplicationInfo{
        .p_application_name = app_name,
        .application_version = vk.makeApiVersion(0, 0, 0, 0),
        .p_engine_name = app_name,
        .engine_version = vk.makeApiVersion(0, 0, 0, 0),
        .api_version = vk.API_VERSION_1_2,
    };

    return vkb.createInstance(&.{
        .flags = .{},
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(u32, layers.len),
        .pp_enabled_layer_names = @ptrCast([*]const [*:0]const u8, layers.ptr),
        .enabled_extension_count = @intCast(u32, extensions.len),
        .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, extensions.ptr),
    }, null);
}

fn debugMessengerCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_types: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_types;
    _ = p_user_data;

    if (p_callback_data) |callback_data| {
        const severity = vk.DebugUtilsMessageSeverityFlagsEXT.fromInt(message_severity);
        const prefix = "[VK_VALIDATION]: ";
        const msg = callback_data.p_message;

        if (severity.contains(.{ .info_bit_ext = true })) {
            std.log.info("{s}{s}\n", .{ prefix, msg });
        } else if (severity.contains(.{ .warning_bit_ext = true })) {
            std.log.warn("{s}{s}\n", .{ prefix, msg });
        } else if (severity.contains(.{ .error_bit_ext = true })) {
            std.log.err("{s}{s}\n", .{ prefix, msg });
        } else {
            std.log.err("(Unknown severity) {s}{s}\n", .{ prefix, callback_data.p_message });
        }
    }

    return vk.FALSE;
}

fn initDebugMessenger(instance_: vk.Instance, vki: InstanceDispatch) !vk.DebugUtilsMessengerEXT {
    return try vki.createDebugUtilsMessengerEXT(instance_, &.{
        .flags = .{},
        .message_severity = .{
            // .verbose_bit_ext = true,
            .info_bit_ext = true,
            .warning_bit_ext = true,
            .error_bit_ext = true,
        },
        .message_type = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
        },
        .pfn_user_callback = debugMessengerCallback,
        .p_user_data = null,
    }, null);
}

fn createSurface(instance: vk.Instance, window: glfw.Window) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    const result = try glfw.createWindowSurface(instance, window, null, &surface);

    if (result != @enumToInt(vk.Result.success)) {
        return error.SurfaceInitFailed;
    }

    return surface;
}

const physical_device_selector = struct {
    fn selectPhysicalDevice(
        instance: vk.Instance,
        vki: InstanceDispatch,
        surface: vk.SurfaceKHR,
        required_extensions: []const [*:0]const u8,
        allocator: Allocator,
    ) !vk.PhysicalDevice {
        const physical_devices = try vk_enumerate.enumeratePhysicalDevices(allocator, vki, instance);
        defer allocator.free(physical_devices);

        var highest_suitability_rating: i32 = -1;
        var highest_suitabliity_rating_index: ?usize = null;

        for (physical_devices) |pd, index| {
            ensureExtensionsSupported(vki, pd, required_extensions, allocator) catch continue;
            ensureHasSurfaceSupport(vki, pd, surface) catch continue;

            const props = vki.getPhysicalDeviceProperties(pd);

            const suitability_rating: i32 = switch (props.device_type) {
                .virtual_gpu => 0,
                .integrated_gpu => 1,
                .discrete_gpu => 2,
                else => -1,
            };

            if (suitability_rating > highest_suitability_rating) {
                highest_suitability_rating = suitability_rating;
                highest_suitabliity_rating_index = index;
            }
        }

        if (highest_suitabliity_rating_index) |index| {
            const selected_pd = physical_devices[index];
            std.log.info("Using physical device: {s}", .{vki.getPhysicalDeviceProperties(selected_pd).device_name});
            return selected_pd;
        } else {
            return error.NoSuitableDevice;
        }
    }

    fn ensureExtensionsSupported(vki: InstanceDispatch, pd: vk.PhysicalDevice, extensions: []const [*:0]const u8, allocator: Allocator) !void {
        // enumerate extensions
        const pd_ext_props = try vk_enumerate.enumerateDeviceExtensionProperties(allocator, vki, pd);
        defer allocator.free(pd_ext_props);

        // check if required extensions are in the physical device's list of supported extensions
        for (extensions) |required_ext_name| {
            for (pd_ext_props) |pd_ext| {
                const pd_ext_name = @ptrCast([*:0]const u8, &pd_ext.extension_name);

                if (std.mem.eql(u8, std.mem.span(required_ext_name), std.mem.span(pd_ext_name))) {
                    break;
                }
            } else {
                return error.ExtensionsNotSupported;
            }
        }
    }

    fn ensureHasSurfaceSupport(vki: InstanceDispatch, pd: vk.PhysicalDevice, surface: vk.SurfaceKHR) !void {
        var format_count: u32 = undefined;
        _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(pd, surface, &format_count, null);

        var present_mode_count: u32 = undefined;
        _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(pd, surface, &present_mode_count, null);

        if (format_count < 1 or present_mode_count < 1) {
            return error.NoSurfaceSupport;
        }
    }
};

const QueueFamilyIndices = struct {
    graphics: u32,
    present: u32,

    fn hasSurfaceSupport(vki: InstanceDispatch, pd: vk.PhysicalDevice, queue_family: u32, surface: vk.SurfaceKHR) !bool {
        return (try vki.getPhysicalDeviceSurfaceSupportKHR(pd, queue_family, surface)) == vk.TRUE;
    }

    fn find(allocator: Allocator, vki: InstanceDispatch, pd: vk.PhysicalDevice, surface: vk.SurfaceKHR) !QueueFamilyIndices {
        const family_properties = try vk_enumerate.getPhysicalDeviceQueueFamilyProperties(allocator, vki, pd);
        defer allocator.free(family_properties);

        var graphics_family: ?u32 = null;
        var present_family: ?u32 = null;

        for (family_properties) |family_props, index| {
            if (graphics_family == null and family_props.queue_flags.graphics_bit) {
                graphics_family = @intCast(u32, index);

                // Since we're currenly only using explicit sharing mode for queues in the swapchain if the queue families are the same,
                //  it's preferable to use the graphics queue as the present queue as well, if it has present support.
                // TODO This may change in the future, once the transfer between queues is explicit.
                const present_supported = try hasSurfaceSupport(vki, pd, graphics_family.?, surface);
                if (present_supported) {
                    present_family = graphics_family;
                    break;
                }
            }

            if (present_family == null and try hasSurfaceSupport(vki, pd, @intCast(u32, index), surface)) {
                present_family = @intCast(u32, index);
            }
        }

        if (graphics_family == null or present_family == null) {
            return error.CouldNotFindQueueFamilies;
        }

        return QueueFamilyIndices{
            .graphics = graphics_family.?,
            .present = present_family.?,
        };
    }
};

fn initDevice(vki: InstanceDispatch, pd: vk.PhysicalDevice, device_extensions: []const [*:0]const u8, queue_family_indices: QueueFamilyIndices) !vk.Device {
    const queue_priority = [_]f32{1};
    const queues_create_info = [_]vk.DeviceQueueCreateInfo{ .{
        .flags = .{},
        .queue_family_index = queue_family_indices.graphics,
        .queue_count = 1,
        .p_queue_priorities = &queue_priority,
    }, .{
        .flags = .{},
        .queue_family_index = queue_family_indices.present,
        .queue_count = 1,
        .p_queue_priorities = &queue_priority,
    } };

    const queue_count: u32 = if (queue_family_indices.graphics == queue_family_indices.present) 1 else 2;

    std.log.info("device extensions count: {}", .{device_extensions.len});

    for (device_extensions) |ext| {
        std.log.info("required device extensions: {s}", .{ext});
    }

    // TODO ensure supported on the physical device
    var vk11_features: vk.PhysicalDeviceVulkan11Features = vk.PhysicalDeviceVulkan11Features{ .shader_draw_parameters = vk.TRUE };

    const features = vk.PhysicalDeviceFeatures2{
        .p_next = &vk11_features,
        .features = .{},
    };

    const create_info = vk.DeviceCreateInfo{
        .p_next = &features,
        .flags = .{},
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &queues_create_info,
        .enabled_layer_count = 0, // legacy
        .pp_enabled_layer_names = undefined, // legacy
        .enabled_extension_count = @intCast(u32, device_extensions.len),
        .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, device_extensions.ptr),
        .p_enabled_features = null, //&features,
    };

    return try vki.createDevice(pd, &create_info, null);
}

fn initDeviceQueue(vkd: DeviceDispatch, device: vk.Device, family: u32) VkContext.DeviceQueue {
    return .{
        .handle = vkd.getDeviceQueue(device, family, 0),
        .family = family,
    };
}
