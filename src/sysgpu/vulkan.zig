const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const sysgpu = @import("sysgpu/main.zig");
const limits = @import("limits.zig");
const shader = @import("shader.zig");
const utils = @import("utils.zig");
const conv = @import("vulkan/conv.zig");
const proc = @import("vulkan/proc.zig");
const mach = @import("../main.zig");

const log = std.log.scoped(.vulkan);
const api_version = vk.makeApiVersion(0, 1, 1, 0);
const upload_page_size = 64 * 1024 * 1024; // TODO - split writes and/or support large uploads
const use_semaphore_wait = false;

var allocator: std.mem.Allocator = undefined;
var libvulkan: ?std.DynLib = null;
var vkb: proc.BaseFunctions = undefined;
var vki: proc.InstanceFunctions = undefined;
var vkd: proc.DeviceFunctions = undefined;

pub const InitOptions = struct {
    baseLoader: ?proc.BaseLoader = null,
};

pub fn init(alloc: std.mem.Allocator, options: InitOptions) !void {
    allocator = alloc;
    if (options.baseLoader) |baseLoader| {
        vkb = try proc.loadBase(baseLoader);
    } else {
        libvulkan = try mach.dynLibOpen(switch (builtin.target.os.tag) {
            .windows => "vulkan-1.dll",
            .linux => "libvulkan.so.1",
            .macos => "libvulkan.1.dylib",
            else => @compileError("Unknown OS!"),
        });
        vkb = try proc.loadBase(libVulkanBaseLoader);
    }
}

pub fn libVulkanBaseLoader(_: vk.Instance, name_ptr: [*:0]const u8) vk.PfnVoidFunction {
    const name = std.mem.span(name_ptr);
    return libvulkan.?.lookup(vk.PfnVoidFunction, name) orelse null;
}

const MapCallback = struct {
    buffer: *Buffer,
    callback: sysgpu.Buffer.MapCallback,
    userdata: ?*anyopaque,
};

pub const Instance = struct {
    manager: utils.Manager(Instance) = .{},
    vk_instance: vk.Instance,

    pub fn init(desc: *const sysgpu.Instance.Descriptor) !*Instance {
        _ = desc;

        // Query layers
        var count: u32 = 0;
        _ = try vkb.enumerateInstanceLayerProperties(&count, null);

        const available_layers = try allocator.alloc(vk.LayerProperties, count);
        defer allocator.free(available_layers);
        _ = try vkb.enumerateInstanceLayerProperties(&count, available_layers.ptr);

        var layers = std.BoundedArray([*:0]const u8, instance_layers.len){};
        for (instance_layers) |optional| {
            for (available_layers) |available| {
                if (std.mem.eql(
                    u8,
                    std.mem.sliceTo(optional, 0),
                    std.mem.sliceTo(&available.layer_name, 0),
                )) {
                    layers.appendAssumeCapacity(optional);
                    break;
                }
            }
        }

        // Query extensions
        _ = try vkb.enumerateInstanceExtensionProperties(null, &count, null);

        const available_extensions = try allocator.alloc(vk.ExtensionProperties, count);
        defer allocator.free(available_extensions);
        _ = try vkb.enumerateInstanceExtensionProperties(null, &count, available_extensions.ptr);

        var extensions = std.BoundedArray([*:0]const u8, instance_extensions.len){};

        for (instance_extensions) |required| {
            for (available_extensions) |available| {
                if (std.mem.eql(
                    u8,
                    std.mem.sliceTo(required, 0),
                    std.mem.sliceTo(&available.extension_name, 0),
                )) {
                    extensions.appendAssumeCapacity(required);
                    break;
                }
            } else {
                log.warn("unable to find required instance extension: {s}", .{required});
            }
        }

        // Create instace
        const application_info = vk.ApplicationInfo{
            .p_engine_name = "Banana",
            .application_version = 0,
            .engine_version = vk.makeApiVersion(0, 0, 1, 0), // TODO: get this from build.zig.zon
            .api_version = api_version,
        };
        const instance_info = vk.InstanceCreateInfo{
            .p_application_info = &application_info,
            .enabled_layer_count = @intCast(layers.len),
            .pp_enabled_layer_names = layers.slice().ptr,
            .enabled_extension_count = @intCast(extensions.len),
            .pp_enabled_extension_names = extensions.slice().ptr,
        };
        const vk_instance = try vkb.createInstance(&instance_info, null);

        // Load instance functions
        vki = try proc.loadInstance(vk_instance, vkb.dispatch.vkGetInstanceProcAddr);

        const instance = try allocator.create(Instance);
        instance.* = .{ .vk_instance = vk_instance };
        return instance;
    }

    const instance_layers = if (builtin.mode == .Debug)
        &[_][*:0]const u8{"VK_LAYER_KHRONOS_validation"}
    else
        &.{};
    const instance_extensions: []const [*:0]const u8 = switch (builtin.target.os.tag) {
        .linux => &.{
            vk.extensions.khr_surface.name,
            vk.extensions.khr_xlib_surface.name,
            vk.extensions.khr_xcb_surface.name,
            vk.extensions.khr_wayland_surface.name,
        },
        .windows => &.{
            vk.extensions.khr_surface.name,
            vk.extensions.khr_win_32_surface.name,
        },
        .macos, .ios => &.{
            vk.extensions.khr_surface.name,
            vk.extensions.ext_metal_surface.name,
        },
        else => |tag| if (builtin.target.abi == .android)
            &.{
                vk.extensions.khr_surface.name,
                vk.extensions.khr_android_surface.name,
            }
        else
            @compileError(std.fmt.comptimePrint("unsupported platform ({s})", .{@tagName(tag)})),
    };

    pub fn deinit(instance: *Instance) void {
        const vk_instance = instance.vk_instance;

        vki.destroyInstance(vk_instance, null);
        allocator.destroy(instance);
        if (libvulkan) |*lib| lib.close();
    }

    pub fn requestAdapter(
        instance: *Instance,
        options: ?*const sysgpu.RequestAdapterOptions,
        callback: sysgpu.RequestAdapterCallback,
        userdata: ?*anyopaque,
    ) !*Adapter {
        return Adapter.init(instance, options orelse &sysgpu.RequestAdapterOptions{}) catch |err| {
            callback(.err, undefined, @errorName(err), userdata);
            @panic("unimplemented"); // TODO - return dummy adapter
        };
    }

    pub fn createSurface(instance: *Instance, desc: *const sysgpu.Surface.Descriptor) !*Surface {
        return Surface.init(instance, desc);
    }
};

pub const Adapter = struct {
    manager: utils.Manager(Adapter) = .{},
    instance: *Instance,
    physical_device: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queue_family: u32,
    extensions: []const vk.ExtensionProperties,
    driver_desc: [:0]const u8,
    vendor_id: VendorID,

    pub fn init(instance: *Instance, options: *const sysgpu.RequestAdapterOptions) !*Adapter {
        const vk_instance = instance.vk_instance;

        var count: u32 = 0;
        _ = try vki.enumeratePhysicalDevices(vk_instance, &count, null);

        var physical_devices = try allocator.alloc(vk.PhysicalDevice, count);
        defer allocator.free(physical_devices);
        _ = try vki.enumeratePhysicalDevices(vk_instance, &count, physical_devices.ptr);

        // Find best device based on power preference
        var physical_device_info: ?struct {
            physical_device: vk.PhysicalDevice,
            props: vk.PhysicalDeviceProperties,
            queue_family: u32,
            score: u32,
        } = null;
        for (physical_devices[0..count]) |physical_device| {
            const props = vki.getPhysicalDeviceProperties(physical_device);
            const features = vki.getPhysicalDeviceFeatures(physical_device);
            const queue_family = try findQueueFamily(physical_device) orelse continue;

            if (isDeviceSuitable(props, features)) {
                const score = rateDevice(props, features, options.power_preference);
                if (score == 0) continue;

                if (physical_device_info == null or score > physical_device_info.?.score) {
                    physical_device_info = .{
                        .physical_device = physical_device,
                        .props = props,
                        .queue_family = queue_family,
                        .score = score,
                    };
                }
            }
        }

        if (physical_device_info) |info| {
            _ = try vki.enumerateDeviceExtensionProperties(info.physical_device, null, &count, null);
            const extensions = try allocator.alloc(vk.ExtensionProperties, count);
            errdefer allocator.free(extensions);
            _ = try vki.enumerateDeviceExtensionProperties(info.physical_device, null, &count, extensions.ptr);

            const driver_desc = try std.fmt.allocPrintZ(
                allocator,
                "Vulkan driver version {}.{}.{}",
                .{
                    vk.apiVersionMajor(info.props.driver_version),
                    vk.apiVersionMinor(info.props.driver_version),
                    vk.apiVersionPatch(info.props.driver_version),
                },
            );

            const adapter = try allocator.create(Adapter);
            adapter.* = .{
                .instance = instance,
                .physical_device = info.physical_device,
                .props = info.props,
                .queue_family = info.queue_family,
                .extensions = extensions,
                .driver_desc = driver_desc,
                .vendor_id = @enumFromInt(info.props.vendor_id),
            };
            return adapter;
        }

        return error.NoAdapterFound;
    }

    pub fn deinit(adapter: *Adapter) void {
        allocator.free(adapter.extensions);
        allocator.free(adapter.driver_desc);
        allocator.destroy(adapter);
    }

    pub fn createDevice(adapter: *Adapter, desc: ?*const sysgpu.Device.Descriptor) !*Device {
        return Device.init(adapter, desc);
    }

    pub fn getProperties(adapter: *Adapter) sysgpu.Adapter.Properties {
        return .{
            .vendor_id = @intFromEnum(adapter.vendor_id),
            .vendor_name = adapter.vendor_id.name(),
            .architecture = "", // TODO
            .device_id = adapter.props.device_id,
            .name = @ptrCast(&adapter.props.device_name),
            .driver_description = adapter.driver_desc,
            .adapter_type = conv.sysgpuAdapterType(adapter.props.device_type),
            .backend_type = .vulkan,
            .compatibility_mode = .false, // TODO
        };
    }

    pub fn hasExtension(adapter: *Adapter, name: []const u8) bool {
        for (adapter.extensions) |ext| {
            if (std.mem.eql(u8, name, std.mem.sliceTo(&ext.extension_name, 0))) {
                return true;
            }
        }
        return false;
    }

    fn isDeviceSuitable(props: vk.PhysicalDeviceProperties, features: vk.PhysicalDeviceFeatures) bool {
        return props.api_version >= api_version and
            // WebGPU features
            features.depth_bias_clamp == vk.TRUE and
            features.fragment_stores_and_atomics == vk.TRUE and
            features.full_draw_index_uint_32 == vk.TRUE and
            features.image_cube_array == vk.TRUE and
            features.independent_blend == vk.TRUE and
            features.sample_rate_shading == vk.TRUE and
            // At least one of the following texture compression forms
            (features.texture_compression_bc == vk.TRUE or
            features.texture_compression_etc2 == vk.TRUE or
            features.texture_compression_astc_ldr == vk.TRUE);
    }

    fn rateDevice(
        props: vk.PhysicalDeviceProperties,
        features: vk.PhysicalDeviceFeatures,
        power_preference: sysgpu.PowerPreference,
    ) u32 {
        _ = features;

        var score: u32 = 0;
        switch (props.device_type) {
            .integrated_gpu => if (power_preference == .low_power) {
                score += 1000;
            },
            .discrete_gpu => if (power_preference == .high_performance) {
                score += 1000;
            },
            else => {},
        }

        score += props.limits.max_image_dimension_2d;

        return score;
    }

    fn findQueueFamily(device: vk.PhysicalDevice) !?u32 {
        var count: u32 = 0;
        _ = vki.getPhysicalDeviceQueueFamilyProperties(device, &count, null);

        const queue_families = try allocator.alloc(vk.QueueFamilyProperties, count);
        defer allocator.free(queue_families);
        _ = vki.getPhysicalDeviceQueueFamilyProperties(device, &count, queue_families.ptr);

        for (queue_families, 0..) |family, i| {
            if (family.queue_flags.graphics_bit and family.queue_flags.compute_bit) {
                return @intCast(i);
            }
        }

        return null;
    }

    const VendorID = enum(u32) {
        amd = 0x1002,
        apple = 0x106b,
        arm = 0x13B5,
        google = 0x1AE0,
        img_tec = 0x1010,
        intel = 0x8086,
        mesa = 0x10005,
        microsoft = 0x1414,
        nvidia = 0x10DE,
        qualcomm = 0x5143,
        samsung = 0x144d,
        _,

        pub fn name(vendor_id: VendorID) [:0]const u8 {
            return switch (vendor_id) {
                .amd => "AMD",
                .apple => "Apple",
                .arm => "ARM",
                .google => "Google",
                .img_tec => "Img Tec",
                .intel => "Intel",
                .mesa => "Mesa",
                .microsoft => "Microsoft",
                .nvidia => "Nvidia",
                .qualcomm => "Qualcomm",
                .samsung => "Samsung",
                _ => "Unknown",
            };
        }
    };
};

pub const Surface = struct {
    manager: utils.Manager(Surface) = .{},
    instance: *Instance,
    vk_surface: vk.SurfaceKHR,

    pub fn init(instance: *Instance, desc: *const sysgpu.Surface.Descriptor) !*Surface {
        const vk_instance = instance.vk_instance;

        const vk_surface = switch (builtin.target.os.tag) {
            .linux => blk: {
                if (utils.findChained(sysgpu.Surface.DescriptorFromXlibWindow, desc.next_in_chain.generic)) |x_desc| {
                    break :blk try vki.createXlibSurfaceKHR(
                        vk_instance,
                        &vk.XlibSurfaceCreateInfoKHR{
                            .dpy = @ptrCast(x_desc.display),
                            .window = x_desc.window,
                        },
                        null,
                    );
                } else if (utils.findChained(sysgpu.Surface.DescriptorFromWaylandSurface, desc.next_in_chain.generic)) |wayland_desc| {
                    break :blk try vki.createWaylandSurfaceKHR(
                        vk_instance,
                        &vk.WaylandSurfaceCreateInfoKHR{
                            .display = @ptrCast(wayland_desc.display),
                            .surface = @ptrCast(wayland_desc.surface),
                        },
                        null,
                    );
                }

                return error.InvalidDescriptor;
            },
            .windows => blk: {
                if (utils.findChained(sysgpu.Surface.DescriptorFromWindowsHWND, desc.next_in_chain.generic)) |win_desc| {
                    break :blk try vki.createWin32SurfaceKHR(
                        vk_instance,
                        &vk.Win32SurfaceCreateInfoKHR{
                            .hinstance = @ptrCast(win_desc.hinstance),
                            .hwnd = @ptrCast(win_desc.hwnd),
                        },
                        null,
                    );
                }

                return error.InvalidDescriptor;
            },
            else => @compileError("unsupported platform"),
        };

        const surface = try allocator.create(Surface);
        surface.* = .{
            .instance = instance,
            .vk_surface = vk_surface,
        };
        return surface;
    }

    pub fn deinit(surface: *Surface) void {
        const vk_instance = surface.instance.vk_instance;

        vki.destroySurfaceKHR(vk_instance, surface.vk_surface, null);
        allocator.destroy(surface);
    }
};

pub const Device = struct {
    manager: utils.Manager(Device) = .{},
    adapter: *Adapter,
    vk_device: vk.Device,
    render_passes: std.AutoHashMapUnmanaged(RenderPassKey, vk.RenderPass) = .{},
    cmd_pool: vk.CommandPool,
    memory_allocator: MemoryAllocator,
    queue: ?Queue = null,
    streaming_manager: StreamingManager = undefined,
    submit_objects: std.ArrayListUnmanaged(SubmitObject) = .{},
    map_callbacks: std.ArrayListUnmanaged(MapCallback) = .{},
    /// Supported Depth-Stencil formats
    supported_ds_formats: std.AutoHashMapUnmanaged(vk.Format, void),

    lost_cb: ?sysgpu.Device.LostCallback = null,
    lost_cb_userdata: ?*anyopaque = null,
    log_cb: ?sysgpu.LoggingCallback = null,
    log_cb_userdata: ?*anyopaque = null,
    err_cb: ?sysgpu.ErrorCallback = null,
    err_cb_userdata: ?*anyopaque = null,

    pub fn init(adapter: *Adapter, descriptor: ?*const sysgpu.Device.Descriptor) !*Device {
        const queue_infos = &[_]vk.DeviceQueueCreateInfo{.{
            .queue_family_index = adapter.queue_family,
            .queue_count = 1,
            .p_queue_priorities = &[_]f32{1.0},
        }};

        var features = vk.PhysicalDeviceFeatures2{ .features = .{} };
        if (descriptor) |desc| {
            if (desc.required_features) |required_features| {
                for (required_features[0..desc.required_features_count]) |req_feature| {
                    switch (req_feature) {
                        .undefined => break,
                        .depth_clip_control => features.features.depth_clamp = vk.TRUE,
                        .pipeline_statistics_query => features.features.pipeline_statistics_query = vk.TRUE,
                        .texture_compression_bc => features.features.texture_compression_bc = vk.TRUE,
                        .texture_compression_etc2 => features.features.texture_compression_etc2 = vk.TRUE,
                        .texture_compression_astc => features.features.texture_compression_astc_ldr = vk.TRUE,
                        .indirect_first_instance => features.features.draw_indirect_first_instance = vk.TRUE,
                        .shader_f16 => {
                            var feature = vk.PhysicalDeviceShaderFloat16Int8FeaturesKHR{
                                // physical_device_shader_float16_int8_features_khr
                                .s_type = vk.StructureType.physical_device_shader_float16_int8_features_khr,
                                .shader_float_16 = vk.TRUE,
                            };
                            features.p_next = @ptrCast(&feature);
                        },
                        else => log.warn("unimplement feature: {s}", .{@tagName(req_feature)}),
                    }
                }
            }
        }

        // Query layers
        var count: u32 = 0;
        _ = try vki.enumerateDeviceLayerProperties(adapter.physical_device, &count, null);

        const available_layers = try allocator.alloc(vk.LayerProperties, count);
        defer allocator.free(available_layers);
        _ = try vki.enumerateDeviceLayerProperties(adapter.physical_device, &count, available_layers.ptr);

        var layers = std.BoundedArray([*:0]const u8, device_layers.len){};
        for (device_layers) |optional| {
            for (available_layers) |available| {
                if (std.mem.eql(
                    u8,
                    std.mem.sliceTo(optional, 0),
                    std.mem.sliceTo(&available.layer_name, 0),
                )) {
                    layers.appendAssumeCapacity(optional);
                    break;
                }
            }
        }

        // Query extensions
        _ = try vki.enumerateDeviceExtensionProperties(adapter.physical_device, null, &count, null);

        const available_extensions = try allocator.alloc(vk.ExtensionProperties, count);
        defer allocator.free(available_extensions);
        _ = try vki.enumerateDeviceExtensionProperties(adapter.physical_device, null, &count, available_extensions.ptr);

        var extensions = std.BoundedArray([*:0]const u8, device_extensions.len){};
        for (device_extensions) |required| {
            for (available_extensions) |available| {
                if (std.mem.eql(
                    u8,
                    std.mem.sliceTo(required, 0),
                    std.mem.sliceTo(&available.extension_name, 0),
                )) {
                    extensions.appendAssumeCapacity(required);
                    break;
                }
            } else {
                log.warn("unable to find required device extension: {s}", .{required});
            }
        }

        var create_info = vk.DeviceCreateInfo{
            .queue_create_info_count = @intCast(queue_infos.len),
            .p_queue_create_infos = queue_infos.ptr,
            .enabled_layer_count = @intCast(layers.len),
            .pp_enabled_layer_names = layers.slice().ptr,
            .enabled_extension_count = @intCast(extensions.len),
            .pp_enabled_extension_names = extensions.slice().ptr,
        };
        if (adapter.hasExtension("GetPhysicalDeviceProperties2")) {
            create_info.p_next = &features;
        } else {
            create_info.p_enabled_features = &features.features;
        }

        const vk_device = try vki.createDevice(adapter.physical_device, &create_info, null);
        vkd = try proc.loadDevice(vk_device, vki.dispatch.vkGetDeviceProcAddr);

        var supported_ds_formats = std.AutoHashMapUnmanaged(vk.Format, void){};
        for ([_]vk.Format{ .d24_unorm_s8_uint, .s8_uint }) |format| {
            const properties = vki.getPhysicalDeviceFormatProperties(adapter.physical_device, format);
            if (properties.optimal_tiling_features.depth_stencil_attachment_bit) {
                try supported_ds_formats.put(allocator, format, {});
            }
        }

        const cmd_pool = try vkd.createCommandPool(vk_device, &.{
            .queue_family_index = adapter.queue_family,
            .flags = .{ .reset_command_buffer_bit = true },
        }, null);

        const memory_allocator = MemoryAllocator.init(adapter.physical_device);

        var device = try allocator.create(Device);
        device.* = .{
            .adapter = adapter,
            .vk_device = vk_device,
            .cmd_pool = cmd_pool,
            .memory_allocator = memory_allocator,
            .supported_ds_formats = supported_ds_formats,
        };
        device.streaming_manager = try StreamingManager.init(device);
        errdefer device.streaming_manager.deinit();
        return device;
    }

    pub fn deinit(device: *Device) void {
        const vk_device = device.vk_device;

        device.waitAll() catch {};
        device.processQueuedOperations();

        device.map_callbacks.deinit(allocator);
        for (device.submit_objects.items) |*submit_object| submit_object.deinit();
        device.submit_objects.deinit(allocator);
        device.streaming_manager.deinit();

        var rp_iter = device.render_passes.valueIterator();
        while (rp_iter.next()) |render_pass| {
            vkd.destroyRenderPass(vk_device, render_pass.*, null);
        }
        device.render_passes.deinit(allocator);
        device.supported_ds_formats.deinit(allocator);

        vkd.destroyCommandPool(vk_device, device.cmd_pool, null);
        if (device.queue) |*queue| queue.manager.release();
        vkd.destroyDevice(vk_device, null);
        allocator.destroy(device);
    }

    fn waitAll(device: *Device) !void {
        for (device.submit_objects.items) |*submit_object| try submit_object.wait();
    }

    pub fn createBindGroup(device: *Device, desc: *const sysgpu.BindGroup.Descriptor) !*BindGroup {
        return BindGroup.init(device, desc);
    }

    pub fn createBindGroupLayout(device: *Device, desc: *const sysgpu.BindGroupLayout.Descriptor) !*BindGroupLayout {
        return BindGroupLayout.init(device, desc);
    }

    pub fn createBuffer(device: *Device, desc: *const sysgpu.Buffer.Descriptor) !*Buffer {
        return Buffer.init(device, desc);
    }

    pub fn createCommandEncoder(device: *Device, desc: *const sysgpu.CommandEncoder.Descriptor) !*CommandEncoder {
        return CommandEncoder.init(device, desc);
    }

    pub fn createComputePipeline(device: *Device, desc: *const sysgpu.ComputePipeline.Descriptor) !*ComputePipeline {
        return ComputePipeline.init(device, desc);
    }

    pub fn createPipelineLayout(device: *Device, desc: *const sysgpu.PipelineLayout.Descriptor) !*PipelineLayout {
        return PipelineLayout.init(device, desc);
    }

    pub fn createRenderPipeline(device: *Device, desc: *const sysgpu.RenderPipeline.Descriptor) !*RenderPipeline {
        return RenderPipeline.init(device, desc);
    }

    pub fn createSampler(device: *Device, desc: *const sysgpu.Sampler.Descriptor) !*Sampler {
        return Sampler.init(device, desc);
    }

    pub fn createShaderModuleAir(device: *Device, air: *shader.Air, label: [*:0]const u8) !*ShaderModule {
        _ = label;
        return ShaderModule.initAir(device, air);
    }

    pub fn createShaderModuleSpirv(device: *Device, code: [*]const u32, code_size: u32) !*ShaderModule {
        const vk_shader_module = try vkd.createShaderModule(device.vk_device, &vk.ShaderModuleCreateInfo{
            .code_size = code_size,
            .p_code = code,
        }, null);

        const module = try allocator.create(ShaderModule);
        module.* = .{
            .device = device,
            .vk_shader_module = vk_shader_module,
        };
        return module;
    }

    pub fn createShaderModuleHLSL(device: *Device, code: []const u8) !*ShaderModule {
        _ = code;
        _ = device;
        return error.Unsupported;
    }

    pub fn createShaderModuleMSL(
        device: *Device,
        label: [*:0]const u8,
        code: []const u8,
        workgroup_size: sysgpu.ShaderModule.WorkgroupSize,
    ) !*ShaderModule {
        _ = label;
        _ = code;
        _ = device;
        _ = workgroup_size;
        return error.Unsupported;
    }

    pub fn createSwapChain(device: *Device, surface: *Surface, desc: *const sysgpu.SwapChain.Descriptor) !*SwapChain {
        return SwapChain.init(device, surface, desc);
    }

    pub fn createTexture(device: *Device, desc: *const sysgpu.Texture.Descriptor) !*Texture {
        return Texture.init(device, desc);
    }

    pub fn getQueue(device: *Device) !*Queue {
        if (device.queue == null) {
            device.queue = try Queue.init(device);
        }
        return &device.queue.?;
    }

    pub fn tick(device: *Device) !void {
        if (device.queue) |*queue| try queue.flush();
        device.processQueuedOperations();
    }

    const device_layers = if (builtin.mode == .Debug)
        &[_][*:0]const u8{"VK_LAYER_KHRONOS_validation"}
    else
        &.{};
    const device_extensions = &[_][*:0]const u8{vk.extensions.khr_swapchain.name};

    pub const ResolveKey = struct {
        format: vk.Format,
        layout: vk.ImageLayout,
    };

    pub const ColorAttachmentKey = struct {
        format: vk.Format,
        samples: u32,
        load_op: sysgpu.LoadOp,
        store_op: sysgpu.StoreOp,
        layout: vk.ImageLayout,
        resolve: ?ResolveKey,
    };

    pub const DepthStencilAttachmentKey = struct {
        format: vk.Format,
        samples: u32,
        depth_load_op: sysgpu.LoadOp,
        depth_store_op: sysgpu.StoreOp,
        stencil_load_op: sysgpu.LoadOp,
        stencil_store_op: sysgpu.StoreOp,
        layout: vk.ImageLayout,
        read_only: bool,
    };

    pub const RenderPassKey = struct {
        colors: std.BoundedArray(ColorAttachmentKey, 8),
        depth_stencil: ?DepthStencilAttachmentKey,

        pub fn init() RenderPassKey {
            var colors = std.BoundedArray(ColorAttachmentKey, 8){};
            for (&colors.buffer) |*color| {
                color.* = .{
                    .format = .undefined,
                    .samples = 1,
                    .load_op = .load,
                    .store_op = .store,
                    .layout = .undefined,
                    .resolve = null,
                };
            }

            return .{
                .colors = .{},
                .depth_stencil = null,
            };
        }
    };

    fn createRenderPass(device: *Device, key: RenderPassKey) !vk.RenderPass {
        const vk_device = device.vk_device;

        if (device.render_passes.get(key)) |render_pass| return render_pass;

        var attachments = std.BoundedArray(vk.AttachmentDescription, 8){};
        var color_refs = std.BoundedArray(vk.AttachmentReference, 8){};
        var resolve_refs = std.BoundedArray(vk.AttachmentReference, 8){};
        for (key.colors.slice()) |attach| {
            attachments.appendAssumeCapacity(.{
                .format = attach.format,
                .samples = conv.vulkanSampleCount(attach.samples),
                .load_op = conv.vulkanLoadOp(attach.load_op),
                .store_op = conv.vulkanStoreOp(attach.store_op),
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = attach.layout,
                .final_layout = attach.layout,
            });
            color_refs.appendAssumeCapacity(.{
                .attachment = @intCast(attachments.len - 1),
                .layout = .color_attachment_optimal,
            });

            if (attach.resolve) |resolve| {
                attachments.appendAssumeCapacity(.{
                    .format = resolve.format,
                    .samples = conv.vulkanSampleCount(1),
                    .load_op = .dont_care,
                    .store_op = .store,
                    .stencil_load_op = .dont_care,
                    .stencil_store_op = .dont_care,
                    .initial_layout = resolve.layout,
                    .final_layout = resolve.layout,
                });
                resolve_refs.appendAssumeCapacity(.{
                    .attachment = @intCast(attachments.len - 1),
                    .layout = .color_attachment_optimal,
                });
            }
        }

        const depth_stencil_ref = if (key.depth_stencil) |depth_stencil| blk: {
            const layout: vk.ImageLayout = if (depth_stencil.read_only)
                .depth_stencil_read_only_optimal
            else
                .depth_stencil_attachment_optimal;

            attachments.appendAssumeCapacity(.{
                .format = depth_stencil.format,
                .samples = conv.vulkanSampleCount(depth_stencil.samples),
                .load_op = conv.vulkanLoadOp(depth_stencil.depth_load_op),
                .store_op = conv.vulkanStoreOp(depth_stencil.depth_store_op),
                .stencil_load_op = conv.vulkanLoadOp(depth_stencil.stencil_load_op),
                .stencil_store_op = conv.vulkanStoreOp(depth_stencil.stencil_store_op),
                .initial_layout = depth_stencil.layout,
                .final_layout = depth_stencil.layout,
            });

            break :blk &vk.AttachmentReference{
                .attachment = @intCast(attachments.len - 1),
                .layout = layout,
            };
        } else null;

        const render_pass = try vkd.createRenderPass(vk_device, &vk.RenderPassCreateInfo{
            .attachment_count = @intCast(attachments.len),
            .p_attachments = attachments.slice().ptr,
            .subpass_count = 1,
            .p_subpasses = &[_]vk.SubpassDescription{
                .{
                    .pipeline_bind_point = .graphics,
                    .color_attachment_count = @intCast(color_refs.len),
                    .p_color_attachments = color_refs.slice().ptr,
                    .p_resolve_attachments = if (resolve_refs.len != 0) resolve_refs.slice().ptr else null,
                    .p_depth_stencil_attachment = depth_stencil_ref,
                },
            },
        }, null);

        try device.render_passes.put(allocator, key, render_pass);

        return render_pass;
    }

    pub fn processQueuedOperations(device: *Device) void {
        const vk_device = device.vk_device;

        // Submit objects
        {
            var i: usize = 0;
            while (i < device.submit_objects.items.len) {
                var submit_object = device.submit_objects.items[i];

                const status = vkd.getFenceStatus(vk_device, submit_object.fence) catch unreachable;
                if (status == .success) {
                    submit_object.deinit();
                    _ = device.submit_objects.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // MapAsync
        {
            var i: usize = 0;
            while (i < device.map_callbacks.items.len) {
                const map_callback = device.map_callbacks.items[i];

                if (map_callback.buffer.gpu_count == 0) {
                    map_callback.buffer.executeMapAsync(map_callback);

                    _ = device.map_callbacks.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }
};

pub const SubmitObject = struct {
    device: *Device,
    fence: vk.Fence,
    reference_trackers: std.ArrayListUnmanaged(*ReferenceTracker) = .{},

    pub fn init(device: *Device) !SubmitObject {
        const vk_device = device.vk_device;

        const fence = try vkd.createFence(vk_device, &.{ .flags = .{ .signaled_bit = false } }, null);

        return .{
            .device = device,
            .fence = fence,
        };
    }

    pub fn deinit(object: *SubmitObject) void {
        const vk_device = object.device.vk_device;

        for (object.reference_trackers.items) |reference_tracker| reference_tracker.deinit();
        vkd.destroyFence(vk_device, object.fence, null);
        object.reference_trackers.deinit(allocator);
    }

    pub fn wait(object: *SubmitObject) !void {
        const vk_device = object.device.vk_device;

        _ = try vkd.waitForFences(vk_device, 1, &[_]vk.Fence{object.fence}, vk.TRUE, std.math.maxInt(u64));
    }
};

pub const StreamingManager = struct {
    device: *Device,
    free_buffers: std.ArrayListUnmanaged(*Buffer) = .{},

    pub fn init(device: *Device) !StreamingManager {
        return .{
            .device = device,
        };
    }

    pub fn deinit(manager: *StreamingManager) void {
        for (manager.free_buffers.items) |buffer| buffer.manager.release();
        manager.free_buffers.deinit(allocator);
    }

    pub fn acquire(manager: *StreamingManager) !*Buffer {
        const device = manager.device;

        // Recycle finished buffers
        if (manager.free_buffers.items.len == 0) {
            device.processQueuedOperations();
        }

        // Create new buffer
        if (manager.free_buffers.items.len == 0) {
            const buffer = try Buffer.init(device, &.{
                .label = "upload",
                .usage = .{
                    .copy_src = true,
                    .map_write = true,
                },
                .size = upload_page_size,
                .mapped_at_creation = .true,
            });
            errdefer _ = buffer.manager.release();

            try manager.free_buffers.append(allocator, buffer);
        }

        // Result
        return manager.free_buffers.pop();
    }

    pub fn release(manager: *StreamingManager, buffer: *Buffer) void {
        manager.free_buffers.append(allocator, buffer) catch {
            std.debug.panic("OutOfMemory", .{});
        };
    }
};

pub const SwapChain = struct {
    manager: utils.Manager(SwapChain) = .{},
    device: *Device,
    vk_swapchain: vk.SwapchainKHR,
    fence: vk.Fence,
    wait_semaphore: vk.Semaphore,
    signal_semaphore: vk.Semaphore,
    textures: []*Texture,
    texture_views: []*TextureView,
    texture_index: u32 = 0,
    current_texture_view: ?*TextureView = null,
    format: sysgpu.Texture.Format,

    pub fn init(device: *Device, surface: *Surface, desc: *const sysgpu.SwapChain.Descriptor) !*SwapChain {
        const vk_device = device.vk_device;

        const sc = try allocator.create(SwapChain);

        const capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(
            device.adapter.physical_device,
            surface.vk_surface,
        );

        // TODO: query surface formats
        // TODO: query surface present modes

        const composite_alpha = blk: {
            const composite_alpha_flags = [_]vk.CompositeAlphaFlagsKHR{
                .{ .opaque_bit_khr = true },
                .{ .pre_multiplied_bit_khr = true },
                .{ .post_multiplied_bit_khr = true },
                .{ .inherit_bit_khr = true },
            };
            for (composite_alpha_flags) |flag| {
                if (@as(vk.Flags, @bitCast(flag)) & @as(vk.Flags, @bitCast(capabilities.supported_composite_alpha)) != 0) {
                    break :blk flag;
                }
            }
            break :blk vk.CompositeAlphaFlagsKHR{};
        };
        const image_count = @max(capabilities.min_image_count + 1, capabilities.max_image_count);
        const format = conv.vulkanFormat(device, desc.format);
        const extent = vk.Extent2D{
            .width = std.math.clamp(
                desc.width,
                capabilities.min_image_extent.width,
                capabilities.max_image_extent.width,
            ),
            .height = std.math.clamp(
                desc.height,
                capabilities.min_image_extent.height,
                capabilities.max_image_extent.height,
            ),
        };
        const image_usage = conv.vulkanImageUsageFlags(desc.usage, desc.format);
        const present_mode = conv.vulkanPresentMode(desc.present_mode);

        const vk_swapchain = try vkd.createSwapchainKHR(vk_device, &.{
            .surface = surface.vk_surface,
            .min_image_count = image_count,
            .image_format = format,
            .image_color_space = .srgb_nonlinear_khr,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = image_usage,
            .image_sharing_mode = .exclusive,
            .pre_transform = .{ .identity_bit_khr = true },
            .composite_alpha = composite_alpha,
            .present_mode = present_mode,
            .clipped = vk.FALSE,
        }, null);

        const fence = try vkd.createFence(vk_device, &.{ .flags = .{ .signaled_bit = false } }, null);
        errdefer vkd.destroyFence(vk_device, fence, null);

        const wait_semaphore = try vkd.createSemaphore(vk_device, &.{}, null);
        errdefer vkd.destroySemaphore(vk_device, wait_semaphore, null);

        const signal_semaphore = try vkd.createSemaphore(vk_device, &.{}, null);
        errdefer vkd.destroySemaphore(vk_device, signal_semaphore, null);

        var images_len: u32 = 0;
        _ = try vkd.getSwapchainImagesKHR(vk_device, vk_swapchain, &images_len, null);
        const images = try allocator.alloc(vk.Image, images_len);
        defer allocator.free(images);
        _ = try vkd.getSwapchainImagesKHR(vk_device, vk_swapchain, &images_len, images.ptr);

        const textures = try allocator.alloc(*Texture, images_len);
        errdefer allocator.free(textures);
        const texture_views = try allocator.alloc(*TextureView, images_len);
        errdefer allocator.free(texture_views);

        for (0..images_len) |i| {
            const texture = try Texture.initForSwapChain(device, desc, images[i], sc);
            textures[i] = texture;
            texture_views[i] = try texture.createView(&.{
                .format = desc.format,
                .dimension = .dimension_2d,
            });
        }

        sc.* = .{
            .device = device,
            .vk_swapchain = vk_swapchain,
            .fence = fence,
            .wait_semaphore = wait_semaphore,
            .signal_semaphore = signal_semaphore,
            .textures = textures,
            .texture_views = texture_views,
            .format = desc.format,
        };

        return sc;
    }

    pub fn deinit(sc: *SwapChain) void {
        const vk_device = sc.device.vk_device;

        sc.device.waitAll() catch {};

        for (sc.texture_views) |view| view.manager.release();
        for (sc.textures) |texture| texture.manager.release();
        vkd.destroySemaphore(vk_device, sc.wait_semaphore, null);
        vkd.destroySemaphore(vk_device, sc.signal_semaphore, null);
        vkd.destroyFence(vk_device, sc.fence, null);
        vkd.destroySwapchainKHR(vk_device, sc.vk_swapchain, null);
        allocator.free(sc.textures);
        allocator.free(sc.texture_views);
        allocator.destroy(sc);
    }

    pub fn getCurrentTextureView(sc: *SwapChain) !*TextureView {
        const vk_device = sc.device.vk_device;

        if (sc.current_texture_view) |view| {
            view.manager.reference();
            return view;
        }

        const result = try vkd.acquireNextImageKHR(
            vk_device,
            sc.vk_swapchain,
            std.math.maxInt(u64),
            if (use_semaphore_wait) sc.wait_semaphore else .null_handle,
            if (!use_semaphore_wait) sc.fence else .null_handle,
        );

        // Wait on the CPU so that GPU does not stall later during present.
        // This should be similar to using DXGI Waitable Object.
        if (!use_semaphore_wait) {
            _ = try vkd.waitForFences(vk_device, 1, &[_]vk.Fence{sc.fence}, vk.TRUE, std.math.maxInt(u64));
            try vkd.resetFences(vk_device, 1, &[_]vk.Fence{sc.fence});
        }

        sc.texture_index = result.image_index;
        var view = sc.texture_views[sc.texture_index];
        view.manager.reference();
        sc.current_texture_view = view;

        return view;
    }

    pub fn present(sc: *SwapChain) !void {
        const queue = try sc.device.getQueue();
        const vk_queue = queue.vk_queue;

        const semaphore = sc.signal_semaphore;
        try queue.signal_semaphores.append(allocator, semaphore);
        try queue.flush();

        _ = try vkd.queuePresentKHR(vk_queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &[_]vk.Semaphore{semaphore},
            .swapchain_count = 1,
            .p_swapchains = &[_]vk.SwapchainKHR{sc.vk_swapchain},
            .p_image_indices = &[_]u32{sc.texture_index},
        });

        sc.current_texture_view = null;
    }
};

pub const Buffer = struct {
    manager: utils.Manager(Buffer) = .{},
    device: *Device,
    vk_buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    // NOTE - this is a naive sync solution as a placeholder until render graphs are implemented
    read_stage_mask: vk.PipelineStageFlags,
    read_access_mask: vk.AccessFlags,
    stage_buffer: ?*Buffer,
    gpu_count: u32 = 0,
    map: ?[*]u8,
    // TODO - packed buffer descriptor struct
    size: u64,
    usage: sysgpu.Buffer.UsageFlags,

    pub fn init(device: *Device, desc: *const sysgpu.Buffer.Descriptor) !*Buffer {
        const vk_device = device.vk_device;

        // Buffer
        const size = @max(4, desc.size);

        var usage = desc.usage;
        if (desc.mapped_at_creation == .true and !desc.usage.map_write)
            usage.copy_dst = true;

        const vk_buffer = try vkd.createBuffer(vk_device, &.{
            .size = size,
            .usage = conv.vulkanBufferUsageFlags(usage),
            .sharing_mode = .exclusive,
        }, null);

        // Memory
        const requirements = vkd.getBufferMemoryRequirements(vk_device, vk_buffer);

        const mem_type: MemoryAllocator.MemoryKind = blk: {
            if (desc.usage.map_read) break :blk .linear_read_mappable;
            if (desc.usage.map_write) break :blk .linear_write_mappable;
            break :blk .linear;
        };
        const mem_type_index = device.memory_allocator.findBestAllocator(requirements, mem_type) orelse @panic("unimplemented"); // TODO

        const memory = try vkd.allocateMemory(vk_device, &.{
            .allocation_size = requirements.size,
            .memory_type_index = mem_type_index,
        }, null);

        try vkd.bindBufferMemory(vk_device, vk_buffer, memory, 0);

        // Upload buffer
        var stage_buffer: ?*Buffer = null;
        var map: ?*anyopaque = null;
        if (desc.mapped_at_creation == .true) {
            if (!desc.usage.map_write) {
                stage_buffer = try Buffer.init(device, &.{
                    .usage = .{
                        .copy_src = true,
                        .map_write = true,
                    },
                    .size = size,
                });
                map = try vkd.mapMemory(vk_device, stage_buffer.?.memory, 0, size, .{});
            } else {
                map = try vkd.mapMemory(vk_device, memory, 0, size, .{});
            }
        }

        // Result
        const buffer = try allocator.create(Buffer);
        buffer.* = .{
            .device = device,
            .vk_buffer = vk_buffer,
            .memory = memory,
            .read_stage_mask = conv.vulkanPipelineStageFlagsForBufferRead(desc.usage),
            .read_access_mask = conv.vulkanAccessFlagsForBufferRead(desc.usage),
            .stage_buffer = stage_buffer,
            .map = @ptrCast(map),
            .size = desc.size,
            .usage = desc.usage,
        };

        return buffer;
    }

    pub fn deinit(buffer: *Buffer) void {
        const vk_device = buffer.device.vk_device;

        if (buffer.stage_buffer) |stage_buffer| stage_buffer.manager.release();
        vkd.freeMemory(vk_device, buffer.memory, null);
        vkd.destroyBuffer(vk_device, buffer.vk_buffer, null);
        allocator.destroy(buffer);
    }

    pub fn getMappedRange(buffer: *Buffer, offset: usize, size: usize) !?*anyopaque {
        return @ptrCast(buffer.map.?[offset .. offset + size]);
    }

    pub fn getSize(buffer: *Buffer) u64 {
        return buffer.size;
    }

    pub fn getUsage(buffer: *Buffer) sysgpu.Buffer.UsageFlags {
        return buffer.usage;
    }

    pub fn mapAsync(
        buffer: *Buffer,
        mode: sysgpu.MapModeFlags,
        offset: usize,
        size: usize,
        callback: sysgpu.Buffer.MapCallback,
        userdata: ?*anyopaque,
    ) !void {
        _ = size;
        _ = offset;
        _ = mode;

        const map_callback = MapCallback{ .buffer = buffer, .callback = callback, .userdata = userdata };
        if (buffer.gpu_count == 0) {
            buffer.executeMapAsync(map_callback);
        } else {
            try buffer.device.map_callbacks.append(allocator, map_callback);
        }
    }

    pub fn setLabel(buffer: *Buffer, label: [*:0]const u8) void {
        _ = label;
        _ = buffer;
        @panic("unimplemented");
    }

    pub fn unmap(buffer: *Buffer) !void {
        const vk_device = buffer.device.vk_device;
        const queue = try buffer.device.getQueue();

        var unmap_memory: vk.DeviceMemory = undefined;
        if (buffer.stage_buffer) |stage_buffer| {
            unmap_memory = stage_buffer.memory;
            const encoder = try queue.getCommandEncoder();
            try encoder.copyBufferToBuffer(stage_buffer, 0, buffer, 0, buffer.size);
            stage_buffer.manager.release();
            buffer.stage_buffer = null;
        } else {
            unmap_memory = buffer.memory;
        }
        vkd.unmapMemory(vk_device, unmap_memory);
    }

    // Internal
    pub fn executeMapAsync(buffer: *Buffer, map_callback: MapCallback) void {
        const vk_device = buffer.device.vk_device;

        const map = vkd.mapMemory(vk_device, buffer.memory, 0, buffer.size, .{}) catch {
            map_callback.callback(.unknown, map_callback.userdata);
            return;
        };

        buffer.map = @ptrCast(map);
        map_callback.callback(.success, map_callback.userdata);
    }
};

pub const Texture = struct {
    manager: utils.Manager(Texture) = .{},
    device: *Device,
    extent: vk.Extent2D,
    image: vk.Image,
    memory: vk.DeviceMemory,
    swapchain: ?*SwapChain = null,
    // NOTE - this is a naive sync solution as a placeholder until render graphs are implemented
    read_stage_mask: vk.PipelineStageFlags,
    read_access_mask: vk.AccessFlags,
    read_image_layout: vk.ImageLayout,
    // TODO - packed texture descriptor struct
    usage: sysgpu.Texture.UsageFlags,
    dimension: sysgpu.Texture.Dimension,
    size: sysgpu.Extent3D,
    format: sysgpu.Texture.Format,
    mip_level_count: u32,
    sample_count: u32,

    pub fn init(device: *Device, desc: *const sysgpu.Texture.Descriptor) !*Texture {
        const vk_device = device.vk_device;

        // Image
        const cube_compatible =
            desc.dimension == .dimension_2d and
            desc.size.width == desc.size.height and
            desc.size.depth_or_array_layers >= 6;
        const extent = utils.calcExtent(desc.dimension, desc.size);

        const vk_image = try vkd.createImage(vk_device, &.{
            .flags = conv.vulkanImageCreateFlags(cube_compatible, desc.view_format_count),
            .image_type = conv.vulkanImageType(desc.dimension),
            .format = conv.vulkanFormat(device, desc.format),
            .extent = .{ .width = extent.width, .height = extent.height, .depth = extent.depth },
            .mip_levels = desc.mip_level_count,
            .array_layers = extent.array_count,
            .samples = conv.vulkanSampleCount(desc.sample_count),
            .tiling = .optimal,
            .usage = conv.vulkanImageUsageFlags(desc.usage, desc.format),
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);

        // Memory
        const requirements = vkd.getImageMemoryRequirements(vk_device, vk_image);

        const mem_type = .linear;
        const mem_type_index = device.memory_allocator.findBestAllocator(requirements, mem_type) orelse @panic("unimplemented"); // TODO

        const memory = try vkd.allocateMemory(vk_device, &.{
            .allocation_size = requirements.size,
            .memory_type_index = mem_type_index,
        }, null);

        try vkd.bindImageMemory(vk_device, vk_image, memory, 0);

        // Result
        var texture = try allocator.create(Texture);
        texture.* = .{
            .device = device,
            .extent = .{ .width = extent.width, .height = extent.height },
            .image = vk_image,
            .memory = memory,
            .swapchain = null,
            .read_stage_mask = conv.vulkanPipelineStageFlagsForImageRead(desc.usage, desc.format),
            .read_access_mask = conv.vulkanAccessFlagsForImageRead(desc.usage, desc.format),
            .read_image_layout = conv.vulkanImageLayoutForRead(desc.usage, desc.format),
            .usage = desc.usage,
            .dimension = desc.dimension,
            .size = desc.size,
            .format = desc.format,
            .mip_level_count = desc.mip_level_count,
            .sample_count = desc.sample_count,
        };
        errdefer texture.manager.release();

        // Transition to read-state
        const queue = try device.getQueue();
        const encoder = try queue.getCommandEncoder();
        try encoder.state_tracker.initTexture(texture);

        return texture;
    }

    pub fn initForSwapChain(
        device: *Device,
        desc: *const sysgpu.SwapChain.Descriptor,
        image: vk.Image,
        swapchain: *SwapChain,
    ) !*Texture {
        var texture = try allocator.create(Texture);
        texture.* = .{
            .device = device,
            .extent = .{ .width = desc.width, .height = desc.height },
            .image = image,
            .memory = .null_handle,
            .swapchain = swapchain,
            .read_stage_mask = conv.vulkanPipelineStageFlagsForImageRead(desc.usage, desc.format),
            .read_access_mask = conv.vulkanAccessFlagsForImageRead(desc.usage, desc.format),
            .read_image_layout = .present_src_khr,
            .usage = desc.usage,
            .dimension = .dimension_2d,
            .size = .{ .width = desc.width, .height = desc.height, .depth_or_array_layers = 1 },
            .format = desc.format,
            .mip_level_count = 1,
            .sample_count = 1,
        };
        errdefer texture.manager.release();

        // Transition to read-state
        const queue = try device.getQueue();
        const encoder = try queue.getCommandEncoder();
        try encoder.state_tracker.initTexture(texture);

        return texture;
    }

    pub fn deinit(texture: *Texture) void {
        const vk_device = texture.device.vk_device;

        if (texture.swapchain == null) {
            vkd.freeMemory(vk_device, texture.memory, null);
            vkd.destroyImage(vk_device, texture.image, null);
        }
        allocator.destroy(texture);
    }

    pub fn getWidth(texture: *Texture) u32 {
        return texture.size.width;
    }

    pub fn getHeight(texture: *Texture) u32 {
        return texture.size.height;
    }

    pub fn createView(texture: *Texture, desc: *const sysgpu.TextureView.Descriptor) !*TextureView {
        return TextureView.init(texture, desc, texture.extent);
    }
};

pub const TextureView = struct {
    manager: utils.Manager(TextureView) = .{},
    device: *Device,
    texture: *Texture,
    vk_view: vk.ImageView,
    vk_format: vk.Format,
    extent: vk.Extent2D,

    pub fn init(texture: *Texture, desc: *const sysgpu.TextureView.Descriptor, extent: vk.Extent2D) !*TextureView {
        const vk_device = texture.device.vk_device;

        texture.manager.reference();

        const texture_dimension: sysgpu.TextureView.Dimension = switch (texture.dimension) {
            .dimension_1d => .dimension_1d,
            .dimension_2d => .dimension_2d,
            .dimension_3d => .dimension_3d,
        };

        const format = if (desc.format != .undefined) desc.format else texture.format;
        const dimension = if (desc.dimension != .dimension_undefined) desc.dimension else texture_dimension;

        const vk_format = conv.vulkanFormat(texture.device, format);

        const vk_view = try vkd.createImageView(vk_device, &.{
            .image = texture.image,
            .view_type = conv.vulkanImageViewType(dimension),
            .format = vk_format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = conv.vulkanImageAspectFlags(desc.aspect, format),
                .base_mip_level = desc.base_mip_level,
                .level_count = desc.mip_level_count,
                .base_array_layer = desc.base_array_layer,
                .layer_count = desc.array_layer_count,
            },
        }, null);

        const view = try allocator.create(TextureView);
        view.* = .{
            .device = texture.device,
            .texture = texture,
            .vk_view = vk_view,
            .vk_format = vk_format,
            .extent = extent,
        };
        return view;
    }

    pub fn deinit(view: *TextureView) void {
        const vk_device = view.device.vk_device;

        vkd.destroyImageView(vk_device, view.vk_view, null);
        view.texture.manager.release();
        allocator.destroy(view);
    }
};

pub const Sampler = struct {
    manager: utils.Manager(Sampler) = .{},
    device: *Device,
    vk_sampler: vk.Sampler,

    pub fn init(device: *Device, desc: *const sysgpu.Sampler.Descriptor) !*Sampler {
        const vk_device = device.vk_device;

        const vk_sampler = try vkd.createSampler(vk_device, &.{
            .flags = .{},
            .mag_filter = conv.vulkanFilter(desc.mag_filter),
            .min_filter = conv.vulkanFilter(desc.min_filter),
            .mipmap_mode = conv.vulkanSamplerMipmapMode(desc.mipmap_filter),
            .address_mode_u = conv.vulkanSamplerAddressMode(desc.address_mode_u),
            .address_mode_v = conv.vulkanSamplerAddressMode(desc.address_mode_v),
            .address_mode_w = conv.vulkanSamplerAddressMode(desc.address_mode_w),
            .mip_lod_bias = 0,
            .anisotropy_enable = @intFromBool(desc.max_anisotropy > 1),
            .max_anisotropy = @floatFromInt(desc.max_anisotropy),
            .compare_enable = @intFromBool(desc.compare != .undefined),
            .compare_op = if (desc.compare != .undefined) conv.vulkanCompareOp(desc.compare) else .never,
            .min_lod = desc.lod_min_clamp,
            .max_lod = desc.lod_max_clamp,
            .border_color = .float_transparent_black,
            .unnormalized_coordinates = vk.FALSE,
        }, null);

        // Result
        const sampler = try allocator.create(Sampler);
        sampler.* = .{
            .device = device,
            .vk_sampler = vk_sampler,
        };
        return sampler;
    }

    pub fn deinit(sampler: *Sampler) void {
        const vk_device = sampler.device.vk_device;

        vkd.destroySampler(vk_device, sampler.vk_sampler, null);
        allocator.destroy(sampler);
    }
};

pub const BindGroupLayout = struct {
    const Entry = struct {
        binding: u32,
        descriptor_type: vk.DescriptorType,
        image_layout: vk.ImageLayout,
    };

    manager: utils.Manager(BindGroupLayout) = .{},
    device: *Device,
    vk_layout: vk.DescriptorSetLayout,
    desc_types: std.AutoArrayHashMapUnmanaged(vk.DescriptorType, u32),
    entries: std.ArrayListUnmanaged(Entry),

    pub fn init(device: *Device, desc: *const sysgpu.BindGroupLayout.Descriptor) !*BindGroupLayout {
        var bindings = try std.ArrayListUnmanaged(vk.DescriptorSetLayoutBinding).initCapacity(allocator, desc.entry_count);
        defer bindings.deinit(allocator);

        var desc_types = std.AutoArrayHashMap(vk.DescriptorType, u32).init(allocator);
        errdefer desc_types.deinit();

        var entries = try std.ArrayListUnmanaged(Entry).initCapacity(allocator, desc.entry_count);
        errdefer entries.deinit(allocator);

        for (0..desc.entry_count) |entry_index| {
            const entry = desc.entries.?[entry_index];
            const descriptor_type = conv.vulkanDescriptorType(entry);
            if (desc_types.getPtr(descriptor_type)) |count| {
                count.* += 1;
            } else {
                try desc_types.put(descriptor_type, 1);
            }

            bindings.appendAssumeCapacity(.{
                .binding = entry.binding,
                .descriptor_type = descriptor_type,
                .descriptor_count = 1,
                .stage_flags = conv.vulkanShaderStageFlags(entry.visibility),
            });

            entries.appendAssumeCapacity(.{
                .binding = entry.binding,
                .descriptor_type = descriptor_type,
                .image_layout = conv.vulkanImageLayoutForTextureBinding(entry.texture.sample_type),
            });
        }

        const vk_layout = try vkd.createDescriptorSetLayout(device.vk_device, &.{
            .binding_count = @intCast(bindings.items.len),
            .p_bindings = bindings.items.ptr,
        }, null);

        // Result
        const layout = try allocator.create(BindGroupLayout);
        layout.* = .{
            .device = device,
            .vk_layout = vk_layout,
            .desc_types = desc_types.unmanaged,
            .entries = entries,
        };
        return layout;
    }

    pub fn deinit(layout: *BindGroupLayout) void {
        vkd.destroyDescriptorSetLayout(layout.device.vk_device, layout.vk_layout, null);
        layout.desc_types.deinit(allocator);
        layout.entries.deinit(allocator);
        allocator.destroy(layout);
    }

    // Internal
    pub fn getEntry(layout: *BindGroupLayout, binding: u32) ?*const Entry {
        for (layout.entries.items) |*entry| {
            if (entry.binding == binding)
                return entry;
        }

        return null;
    }
};

pub const BindGroup = struct {
    const BufferAccess = struct {
        buffer: *Buffer,
        storage: bool,
    };
    const TextureViewAccess = struct {
        texture_view: *TextureView,
        storage: bool,
    };
    manager: utils.Manager(BindGroup) = .{},
    device: *Device,
    layout: *BindGroupLayout,
    desc_pool: vk.DescriptorPool,
    desc_set: vk.DescriptorSet,
    buffers: std.ArrayListUnmanaged(BufferAccess),
    texture_views: std.ArrayListUnmanaged(TextureViewAccess),
    samplers: std.ArrayListUnmanaged(*Sampler),

    pub fn init(device: *Device, desc: *const sysgpu.BindGroup.Descriptor) !*BindGroup {
        const layout: *BindGroupLayout = @ptrCast(@alignCast(desc.layout));
        layout.manager.reference();

        // The total number of descriptors sets that fits given the max.
        const max_sets: u32 = @intCast(256 / @max(desc.entry_count, 1));

        var pool_sizes = try std.ArrayList(vk.DescriptorPoolSize).initCapacity(allocator, layout.desc_types.count());
        defer pool_sizes.deinit();

        var desc_types_iter = layout.desc_types.iterator();
        while (desc_types_iter.next()) |entry| {
            pool_sizes.appendAssumeCapacity(.{
                .type = entry.key_ptr.*,
                // Grow the number of desciptors in the pool to fit the computed max_sets.
                .descriptor_count = max_sets * entry.value_ptr.*,
            });
        }

        const desc_pool = try vkd.createDescriptorPool(device.vk_device, &vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = max_sets,
            .pool_size_count = @intCast(pool_sizes.items.len),
            .p_pool_sizes = pool_sizes.items.ptr,
        }, null);

        var desc_set: vk.DescriptorSet = undefined;
        try vkd.allocateDescriptorSets(device.vk_device, &vk.DescriptorSetAllocateInfo{
            .descriptor_pool = desc_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&layout.vk_layout),
        }, @ptrCast(&desc_set));

        var writes = try allocator.alloc(vk.WriteDescriptorSet, layout.entries.items.len);
        defer allocator.free(writes);
        var write_image_info = try allocator.alloc(vk.DescriptorImageInfo, layout.entries.items.len);
        defer allocator.free(write_image_info);
        var write_buffer_info = try allocator.alloc(vk.DescriptorBufferInfo, layout.entries.items.len);
        defer allocator.free(write_buffer_info);

        for (0..desc.entry_count) |i| {
            const entry = desc.entries.?[i];
            const layout_entry = layout.getEntry(entry.binding) orelse return error.UnknownBinding;

            writes[i] = .{
                .dst_set = desc_set,
                .dst_binding = layout_entry.binding,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = layout_entry.descriptor_type,
                .p_image_info = undefined,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };

            switch (layout_entry.descriptor_type) {
                .sampler => {
                    const sampler: *Sampler = @ptrCast(@alignCast(entry.sampler.?));

                    write_image_info[i] = .{
                        .sampler = sampler.vk_sampler,
                        .image_view = .null_handle,
                        .image_layout = .undefined,
                    };
                    writes[i].p_image_info = @ptrCast(&write_image_info[i]);
                },
                .sampled_image, .storage_image => {
                    const texture_view: *TextureView = @ptrCast(@alignCast(entry.texture_view.?));

                    write_image_info[i] = .{
                        .sampler = .null_handle,
                        .image_view = texture_view.vk_view,
                        .image_layout = layout_entry.image_layout,
                    };
                    writes[i].p_image_info = @ptrCast(&write_image_info[i]);
                },
                .uniform_buffer,
                .storage_buffer,
                .uniform_buffer_dynamic,
                .storage_buffer_dynamic,
                => {
                    const buffer: *Buffer = @ptrCast(@alignCast(entry.buffer.?));

                    write_buffer_info[i] = .{
                        .buffer = buffer.vk_buffer,
                        .offset = desc.entries.?[i].offset,
                        .range = desc.entries.?[i].size,
                    };
                    writes[i].p_buffer_info = @ptrCast(&write_buffer_info[i]);
                },
                else => unreachable,
            }
        }

        vkd.updateDescriptorSets(device.vk_device, @intCast(writes.len), writes.ptr, 0, undefined);

        // Resource tracking
        var buffers = std.ArrayListUnmanaged(BufferAccess){};
        errdefer buffers.deinit(allocator);

        var texture_views = std.ArrayListUnmanaged(TextureViewAccess){};
        errdefer texture_views.deinit(allocator);

        var samplers = std.ArrayListUnmanaged(*Sampler){};
        errdefer samplers.deinit(allocator);

        for (0..desc.entry_count) |i| {
            const entry = desc.entries.?[i];
            const layout_entry = layout.getEntry(entry.binding) orelse return error.UnknownBinding;

            switch (layout_entry.descriptor_type) {
                .sampler => {
                    const sampler: *Sampler = @ptrCast(@alignCast(entry.sampler.?));

                    try samplers.append(allocator, sampler);
                    sampler.manager.reference();
                },
                .sampled_image, .storage_image => {
                    const texture_view: *TextureView = @ptrCast(@alignCast(entry.texture_view.?));
                    const storage = layout_entry.descriptor_type == .storage_image;

                    try texture_views.append(allocator, .{ .texture_view = texture_view, .storage = storage });
                    texture_view.manager.reference();
                },

                .uniform_buffer,
                .uniform_buffer_dynamic,
                .storage_buffer,
                .storage_buffer_dynamic,
                => {
                    const buffer: *Buffer = @ptrCast(@alignCast(entry.buffer.?));
                    const storage = layout_entry.descriptor_type == .storage_buffer or layout_entry.descriptor_type == .storage_buffer_dynamic;

                    try buffers.append(allocator, .{ .buffer = buffer, .storage = storage });
                    buffer.manager.reference();
                },
                else => unreachable,
            }
        }

        // Result
        const bind_group = try allocator.create(BindGroup);
        bind_group.* = .{
            .device = device,
            .layout = layout,
            .desc_pool = desc_pool,
            .desc_set = desc_set,
            .buffers = buffers,
            .texture_views = texture_views,
            .samplers = samplers,
        };
        return bind_group;
    }

    pub fn deinit(group: *BindGroup) void {
        vkd.destroyDescriptorPool(group.device.vk_device, group.desc_pool, null);

        for (group.buffers.items) |access| access.buffer.manager.release();
        for (group.texture_views.items) |access| access.texture_view.manager.release();
        for (group.samplers.items) |sampler| sampler.manager.release();
        group.layout.manager.release();

        group.buffers.deinit(allocator);
        group.texture_views.deinit(allocator);
        group.samplers.deinit(allocator);
        allocator.destroy(group);
    }
};

pub const PipelineLayout = struct {
    manager: utils.Manager(PipelineLayout) = .{},
    device: *Device,
    vk_layout: vk.PipelineLayout,
    group_layouts: []*BindGroupLayout,

    pub fn init(device: *Device, desc: *const sysgpu.PipelineLayout.Descriptor) !*PipelineLayout {
        const vk_device = device.vk_device;

        var group_layouts = try allocator.alloc(*BindGroupLayout, desc.bind_group_layout_count);
        errdefer allocator.free(group_layouts);

        const set_layouts = try allocator.alloc(vk.DescriptorSetLayout, desc.bind_group_layout_count);
        defer allocator.free(set_layouts);
        for (0..desc.bind_group_layout_count) |i| {
            const layout: *BindGroupLayout = @ptrCast(@alignCast(desc.bind_group_layouts.?[i]));
            layout.manager.reference();
            group_layouts[i] = layout;
            set_layouts[i] = layout.vk_layout;
        }

        const vk_layout = try vkd.createPipelineLayout(vk_device, &.{
            .set_layout_count = @intCast(set_layouts.len),
            .p_set_layouts = set_layouts.ptr,
        }, null);

        const layout = try allocator.create(PipelineLayout);
        layout.* = .{
            .device = device,
            .vk_layout = vk_layout,
            .group_layouts = group_layouts,
        };
        return layout;
    }

    pub fn initDefault(device: *Device, default_pipeline_layout: utils.DefaultPipelineLayoutDescriptor) !*PipelineLayout {
        const groups = default_pipeline_layout.groups;
        var bind_group_layouts = std.BoundedArray(*sysgpu.BindGroupLayout, limits.max_bind_groups){};
        defer {
            for (bind_group_layouts.slice()) |bind_group_layout| bind_group_layout.release();
        }

        for (groups.slice()) |entries| {
            const bind_group_layout = try device.createBindGroupLayout(
                &sysgpu.BindGroupLayout.Descriptor.init(.{ .entries = entries.items }),
            );
            bind_group_layouts.appendAssumeCapacity(@ptrCast(bind_group_layout));
        }

        return device.createPipelineLayout(
            &sysgpu.PipelineLayout.Descriptor.init(.{ .bind_group_layouts = bind_group_layouts.slice() }),
        );
    }

    pub fn deinit(layout: *PipelineLayout) void {
        const vk_device = layout.device.vk_device;

        for (layout.group_layouts) |group_layout| group_layout.manager.release();
        vkd.destroyPipelineLayout(vk_device, layout.vk_layout, null);
        allocator.free(layout.group_layouts);
        allocator.destroy(layout);
    }
};

pub const ShaderModule = struct {
    manager: utils.Manager(ShaderModule) = .{},
    device: *Device,
    vk_shader_module: vk.ShaderModule,
    air: ?*shader.Air = null,

    pub fn initAir(device: *Device, air: *shader.Air) !*ShaderModule {
        const vk_device = device.vk_device;

        const code = try shader.CodeGen.generate(allocator, air, .spirv, true, .{ .emit_source_file = "" }, null, null, null);
        defer allocator.free(code);

        const vk_shader_module = try vkd.createShaderModule(vk_device, &vk.ShaderModuleCreateInfo{
            .code_size = code.len,
            .p_code = @ptrCast(@alignCast(code.ptr)),
        }, null);

        const module = try allocator.create(ShaderModule);
        module.* = .{
            .device = device,
            .vk_shader_module = vk_shader_module,
            .air = air,
        };

        return module;
    }

    pub fn deinit(module: *ShaderModule) void {
        const vk_device = module.device.vk_device;

        vkd.destroyShaderModule(vk_device, module.vk_shader_module, null);
        if (module.air) |air| {
            air.deinit(allocator);
            allocator.destroy(air);
        }
        allocator.destroy(module);
    }
};

pub const ComputePipeline = struct {
    manager: utils.Manager(ComputePipeline) = .{},
    device: *Device,
    layout: *PipelineLayout,
    vk_pipeline: vk.Pipeline,

    pub fn init(device: *Device, desc: *const sysgpu.ComputePipeline.Descriptor) !*ComputePipeline {
        const vk_device = device.vk_device;

        // Shaders
        const compute_module: *ShaderModule = @ptrCast(@alignCast(desc.compute.module));

        // Pipeline Layout
        var layout: *PipelineLayout = undefined;
        if (desc.layout) |layout_raw| {
            layout = @ptrCast(@alignCast(layout_raw));
            layout.manager.reference();
        } else if (compute_module.air) |air| {
            var layout_desc = utils.DefaultPipelineLayoutDescriptor.init(allocator);
            defer layout_desc.deinit();

            try layout_desc.addFunction(air, .{ .compute = true }, desc.compute.entry_point);
            layout = try PipelineLayout.initDefault(device, layout_desc);
        } else {
            @panic(
                \\Cannot create pipeline descriptor autoamtically.
                \\Please provide it yourself or write the shader in WGSL.
            );
        }
        errdefer layout.manager.release();

        // PSO
        const stage = vk.PipelineShaderStageCreateInfo{
            .stage = .{ .compute_bit = true },
            .module = compute_module.vk_shader_module,
            .p_name = desc.compute.entry_point,
        };

        var vk_pipeline: vk.Pipeline = undefined;
        _ = try vkd.createComputePipelines(vk_device, .null_handle, 1, &[_]vk.ComputePipelineCreateInfo{.{
            .base_pipeline_index = -1,
            .layout = layout.vk_layout,
            .stage = stage,
        }}, null, @ptrCast(&vk_pipeline));

        // Result
        const pipeline = try allocator.create(ComputePipeline);
        pipeline.* = .{
            .device = device,
            .vk_pipeline = vk_pipeline,
            .layout = layout,
        };
        return pipeline;
    }

    pub fn deinit(pipeline: *ComputePipeline) void {
        const vk_device = pipeline.device.vk_device;

        pipeline.layout.manager.release();
        vkd.destroyPipeline(vk_device, pipeline.vk_pipeline, null);
        allocator.destroy(pipeline);
    }

    pub fn getBindGroupLayout(pipeline: *ComputePipeline, group_index: u32) *BindGroupLayout {
        return @ptrCast(pipeline.layout.group_layouts[group_index]);
    }
};

pub const RenderPipeline = struct {
    manager: utils.Manager(RenderPipeline) = .{},
    device: *Device,
    vk_pipeline: vk.Pipeline,
    layout: *PipelineLayout,

    pub fn init(device: *Device, desc: *const sysgpu.RenderPipeline.Descriptor) !*RenderPipeline {
        const vk_device = device.vk_device;

        var stages = std.BoundedArray(vk.PipelineShaderStageCreateInfo, 2){};

        const vertex_module: *ShaderModule = @ptrCast(@alignCast(desc.vertex.module));
        stages.appendAssumeCapacity(.{
            .stage = .{ .vertex_bit = true },
            .module = vertex_module.vk_shader_module,
            .p_name = desc.vertex.entry_point,
            .p_specialization_info = null,
        });

        if (desc.fragment) |frag| {
            const frag_module: *ShaderModule = @ptrCast(@alignCast(frag.module));
            stages.appendAssumeCapacity(.{
                .stage = .{ .fragment_bit = true },
                .module = frag_module.vk_shader_module,
                .p_name = frag.entry_point,
                .p_specialization_info = null,
            });
        }

        var vertex_bindings = try std.ArrayList(vk.VertexInputBindingDescription).initCapacity(allocator, desc.vertex.buffer_count);
        var vertex_attrs = try std.ArrayList(vk.VertexInputAttributeDescription).initCapacity(allocator, desc.vertex.buffer_count);
        defer {
            vertex_bindings.deinit();
            vertex_attrs.deinit();
        }

        for (0..desc.vertex.buffer_count) |i| {
            const buf = desc.vertex.buffers.?[i];
            const input_rate = conv.vulkanVertexInputRate(buf.step_mode);

            vertex_bindings.appendAssumeCapacity(.{
                .binding = @intCast(i),
                .stride = @intCast(buf.array_stride),
                .input_rate = input_rate,
            });

            for (0..buf.attribute_count) |j| {
                const attr = buf.attributes.?[j];
                try vertex_attrs.append(.{
                    .location = attr.shader_location,
                    .binding = @intCast(i),
                    .format = conv.vulkanVertexFormat(attr.format),
                    .offset = @intCast(attr.offset),
                });
            }
        }

        const vertex_input = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = @intCast(vertex_bindings.items.len),
            .p_vertex_binding_descriptions = vertex_bindings.items.ptr,
            .vertex_attribute_description_count = @intCast(vertex_attrs.items.len),
            .p_vertex_attribute_descriptions = vertex_attrs.items.ptr,
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = conv.vulkanPrimitiveTopology(desc.primitive.topology),
            .primitive_restart_enable = @intFromBool(desc.primitive.strip_index_format != .undefined),
        };

        const viewport = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .p_viewports = &[_]vk.Viewport{.{ .x = 0, .y = 0, .width = 1.0, .height = 1.0, .min_depth = 0.0, .max_depth = 1.0 }},
            .scissor_count = 1,
            .p_scissors = &[_]vk.Rect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 1, .height = 1 } }},
        };

        const rasterization = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .cull_mode = conv.vulkanCullMode(desc.primitive.cull_mode),
            .front_face = conv.vulkanFrontFace(desc.primitive.front_face),
            .depth_bias_enable = isDepthBiasEnabled(desc.depth_stencil),
            .depth_bias_constant_factor = conv.vulkanDepthBias(desc.depth_stencil),
            .depth_bias_clamp = conv.vulkanDepthBiasClamp(desc.depth_stencil),
            .depth_bias_slope_factor = conv.vulkanDepthBiasSlopeScale(desc.depth_stencil),
            .line_width = 1,
        };

        const sample_count = conv.vulkanSampleCount(desc.multisample.count);
        const multisample = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = sample_count,
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 0,
            .p_sample_mask = &[_]u32{desc.multisample.mask},
            .alpha_to_coverage_enable = @intFromEnum(desc.multisample.alpha_to_coverage_enabled),
            .alpha_to_one_enable = vk.FALSE,
        };

        var layout: *PipelineLayout = undefined;
        if (desc.layout) |layout_raw| {
            layout = @ptrCast(@alignCast(layout_raw));
            layout.manager.reference();
        } else if (vertex_module.air) |vertex_air| {
            var layout_desc = utils.DefaultPipelineLayoutDescriptor.init(allocator);
            defer layout_desc.deinit();

            try layout_desc.addFunction(vertex_air, .{ .vertex = true }, desc.vertex.entry_point);
            if (desc.fragment) |frag| {
                const frag_module: *ShaderModule = @ptrCast(@alignCast(frag.module));
                if (frag_module.air) |frag_air| {
                    try layout_desc.addFunction(frag_air, .{ .fragment = true }, frag.entry_point);
                } else {
                    @panic(
                        \\Cannot create pipeline descriptor autoamtically.
                        \\Please provide it yourself or write the shader in WGSL.
                    );
                }
            }
            layout = try PipelineLayout.initDefault(device, layout_desc);
        } else {
            @panic(
                \\Cannot create pipeline descriptor autoamtically.
                \\Please provide it yourself or write the shader in WGSL.
            );
        }

        errdefer layout.manager.release();

        var blend_attachments: []vk.PipelineColorBlendAttachmentState = &.{};
        defer if (desc.fragment != null) allocator.free(blend_attachments);

        var rp_key = Device.RenderPassKey.init();

        if (desc.fragment) |frag| {
            blend_attachments = try allocator.alloc(vk.PipelineColorBlendAttachmentState, frag.target_count);

            for (0..frag.target_count) |i| {
                const target = frag.targets.?[i];
                const blend = target.blend orelse &sysgpu.BlendState{};
                blend_attachments[i] = .{
                    .blend_enable = if (target.blend != null) vk.TRUE else vk.FALSE,
                    .src_color_blend_factor = conv.vulkanBlendFactor(blend.color.src_factor, true),
                    .dst_color_blend_factor = conv.vulkanBlendFactor(blend.color.dst_factor, true),
                    .color_blend_op = conv.vulkanBlendOp(blend.color.operation),
                    .src_alpha_blend_factor = conv.vulkanBlendFactor(blend.alpha.src_factor, false),
                    .dst_alpha_blend_factor = conv.vulkanBlendFactor(blend.alpha.dst_factor, false),
                    .alpha_blend_op = conv.vulkanBlendOp(blend.alpha.operation),
                    .color_write_mask = .{
                        .r_bit = target.write_mask.red,
                        .g_bit = target.write_mask.green,
                        .b_bit = target.write_mask.blue,
                        .a_bit = target.write_mask.alpha,
                    },
                };
                rp_key.colors.appendAssumeCapacity(.{
                    .format = conv.vulkanFormat(device, target.format),
                    .samples = desc.multisample.count,
                    .load_op = .clear,
                    .store_op = .store,
                    .layout = .color_attachment_optimal,
                    .resolve = null,
                });
            }
        }

        var depth_stencil_state = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = vk.FALSE,
            .depth_write_enable = vk.FALSE,
            .depth_compare_op = .never,
            .depth_bounds_test_enable = vk.FALSE,
            .stencil_test_enable = vk.FALSE,
            .front = .{
                .fail_op = .keep,
                .depth_fail_op = .keep,
                .pass_op = .keep,
                .compare_op = .never,
                .compare_mask = 0,
                .write_mask = 0,
                .reference = 0,
            },
            .back = .{
                .fail_op = .keep,
                .depth_fail_op = .keep,
                .pass_op = .keep,
                .compare_op = .never,
                .compare_mask = 0,
                .write_mask = 0,
                .reference = 0,
            },
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        };

        if (desc.depth_stencil) |ds| {
            depth_stencil_state.depth_test_enable = @intFromBool(ds.depth_compare != .always or ds.depth_write_enabled == .true);
            depth_stencil_state.depth_write_enable = @intFromBool(ds.depth_write_enabled == .true);
            depth_stencil_state.depth_compare_op = conv.vulkanCompareOp(ds.depth_compare);
            depth_stencil_state.stencil_test_enable = @intFromBool(conv.stencilEnable(ds.stencil_front) or conv.stencilEnable(ds.stencil_back));
            depth_stencil_state.front = .{
                .fail_op = conv.vulkanStencilOp(ds.stencil_front.fail_op),
                .depth_fail_op = conv.vulkanStencilOp(ds.stencil_front.depth_fail_op),
                .pass_op = conv.vulkanStencilOp(ds.stencil_front.pass_op),
                .compare_op = conv.vulkanCompareOp(ds.stencil_front.compare),
                .compare_mask = ds.stencil_read_mask,
                .write_mask = ds.stencil_write_mask,
                .reference = 0,
            };
            depth_stencil_state.back = .{
                .fail_op = conv.vulkanStencilOp(ds.stencil_back.fail_op),
                .depth_fail_op = conv.vulkanStencilOp(ds.stencil_back.depth_fail_op),
                .pass_op = conv.vulkanStencilOp(ds.stencil_back.pass_op),
                .compare_op = conv.vulkanCompareOp(ds.stencil_back.compare),
                .compare_mask = ds.stencil_read_mask,
                .write_mask = ds.stencil_write_mask,
                .reference = 0,
            };

            rp_key.depth_stencil = .{
                .format = conv.vulkanFormat(device, ds.format),
                .samples = desc.multisample.count,
                .depth_load_op = .load,
                .depth_store_op = .store,
                .stencil_load_op = .load,
                .stencil_store_op = .store,
                .layout = .depth_stencil_attachment_optimal,
                .read_only = ds.depth_write_enabled == .false and ds.stencil_write_mask == 0,
            };
        }

        const color_blend = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.FALSE,
            .logic_op = .clear,
            .attachment_count = @intCast(blend_attachments.len),
            .p_attachments = blend_attachments.ptr,
            .blend_constants = .{ 0, 0, 0, 0 },
        };

        const dynamic_states = [_]vk.DynamicState{
            .viewport,        .scissor,      .line_width,
            .blend_constants, .depth_bounds, .stencil_reference,
        };
        const dynamic = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };

        const render_pass = try device.createRenderPass(rp_key);

        var vk_pipeline: vk.Pipeline = undefined;
        _ = try vkd.createGraphicsPipelines(vk_device, .null_handle, 1, &[_]vk.GraphicsPipelineCreateInfo{.{
            .stage_count = @intCast(stages.len),
            .p_stages = stages.slice().ptr,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport,
            .p_rasterization_state = &rasterization,
            .p_multisample_state = &multisample,
            .p_depth_stencil_state = &depth_stencil_state,
            .p_color_blend_state = &color_blend,
            .p_dynamic_state = &dynamic,
            .layout = layout.vk_layout,
            .render_pass = render_pass,
            .subpass = 0,
            .base_pipeline_index = -1,
        }}, null, @ptrCast(&vk_pipeline));

        const pipeline = try allocator.create(RenderPipeline);
        pipeline.* = .{
            .device = device,
            .vk_pipeline = vk_pipeline,
            .layout = layout,
        };

        return pipeline;
    }

    pub fn deinit(pipeline: *RenderPipeline) void {
        const vk_device = pipeline.device.vk_device;

        pipeline.layout.manager.release();
        vkd.destroyPipeline(vk_device, pipeline.vk_pipeline, null);
        allocator.destroy(pipeline);
    }

    pub fn getBindGroupLayout(pipeline: *RenderPipeline, group_index: u32) *BindGroupLayout {
        return @ptrCast(pipeline.layout.group_layouts[group_index]);
    }

    fn isDepthBiasEnabled(ds: ?*const sysgpu.DepthStencilState) vk.Bool32 {
        if (ds == null) return vk.FALSE;
        return @intFromBool(ds.?.depth_bias != 0 or ds.?.depth_bias_slope_scale != 0);
    }
};

pub const CommandBuffer = struct {
    pub const StreamingResult = struct {
        buffer: *Buffer,
        map: [*]u8,
        offset: u32,
    };

    manager: utils.Manager(CommandBuffer) = .{},
    device: *Device,
    vk_command_buffer: vk.CommandBuffer,
    wait_semaphores: std.ArrayListUnmanaged(vk.Semaphore) = .{},
    wait_dst_stage_masks: std.ArrayListUnmanaged(vk.PipelineStageFlags) = .{},
    reference_tracker: *ReferenceTracker,
    upload_buffer: ?*Buffer = null,
    upload_map: ?[*]u8 = null,
    upload_next_offset: u32 = upload_page_size,

    pub fn init(device: *Device) !*CommandBuffer {
        const vk_device = device.vk_device;

        var vk_command_buffer: vk.CommandBuffer = undefined;
        try vkd.allocateCommandBuffers(vk_device, &.{
            .command_pool = device.cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&vk_command_buffer));
        try vkd.beginCommandBuffer(vk_command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

        const reference_tracker = try ReferenceTracker.init(device, vk_command_buffer);
        errdefer reference_tracker.deinit();

        const command_buffer = try allocator.create(CommandBuffer);
        command_buffer.* = .{
            .device = device,
            .vk_command_buffer = vk_command_buffer,
            .reference_tracker = reference_tracker,
        };
        return command_buffer;
    }

    pub fn deinit(command_buffer: *CommandBuffer) void {
        // reference_tracker lifetime is managed externally
        // vk_command_buffer lifetime is managed externally
        command_buffer.wait_dst_stage_masks.deinit(allocator);
        command_buffer.wait_semaphores.deinit(allocator);
        allocator.destroy(command_buffer);
    }

    // Internal
    pub fn upload(command_buffer: *CommandBuffer, size: u64) !StreamingResult {
        if (command_buffer.upload_next_offset + size > upload_page_size) {
            const streaming_manager = &command_buffer.device.streaming_manager;

            std.debug.assert(size <= upload_page_size); // TODO - support large uploads
            const buffer = try streaming_manager.acquire();

            try command_buffer.reference_tracker.referenceUploadPage(buffer);
            command_buffer.upload_buffer = buffer;
            command_buffer.upload_map = buffer.map;
            command_buffer.upload_next_offset = 0;
        }

        const offset = command_buffer.upload_next_offset;
        command_buffer.upload_next_offset = @intCast(utils.alignUp(offset + size, limits.min_uniform_buffer_offset_alignment));
        return StreamingResult{
            .buffer = command_buffer.upload_buffer.?,
            .map = command_buffer.upload_map.? + offset,
            .offset = offset,
        };
    }
};

pub const ReferenceTracker = struct {
    device: *Device,
    vk_command_buffer: vk.CommandBuffer,
    buffers: std.ArrayListUnmanaged(*Buffer) = .{},
    textures: std.ArrayListUnmanaged(*Texture) = .{},
    texture_views: std.ArrayListUnmanaged(*TextureView) = .{},
    bind_groups: std.ArrayListUnmanaged(*BindGroup) = .{},
    compute_pipelines: std.ArrayListUnmanaged(*ComputePipeline) = .{},
    render_pipelines: std.ArrayListUnmanaged(*RenderPipeline) = .{},
    upload_pages: std.ArrayListUnmanaged(*Buffer) = .{},
    framebuffers: std.ArrayListUnmanaged(vk.Framebuffer) = .{},

    pub fn init(device: *Device, vk_command_buffer: vk.CommandBuffer) !*ReferenceTracker {
        const tracker = try allocator.create(ReferenceTracker);
        tracker.* = .{
            .device = device,
            .vk_command_buffer = vk_command_buffer,
        };
        return tracker;
    }

    pub fn deinit(tracker: *ReferenceTracker) void {
        const device = tracker.device;
        const vk_device = tracker.device.vk_device;

        vkd.freeCommandBuffers(vk_device, device.cmd_pool, 1, @ptrCast(&tracker.vk_command_buffer));

        for (tracker.buffers.items) |buffer| {
            buffer.gpu_count -= 1;
            buffer.manager.release();
        }

        for (tracker.textures.items) |texture| {
            texture.manager.release();
        }

        for (tracker.texture_views.items) |texture_view| {
            texture_view.manager.release();
        }

        for (tracker.bind_groups.items) |group| {
            for (group.buffers.items) |access| access.buffer.gpu_count -= 1;
            group.manager.release();
        }

        for (tracker.compute_pipelines.items) |pipeline| {
            pipeline.manager.release();
        }

        for (tracker.render_pipelines.items) |pipeline| {
            pipeline.manager.release();
        }

        for (tracker.upload_pages.items) |buffer| {
            device.streaming_manager.release(buffer);
        }

        for (tracker.framebuffers.items) |fb| vkd.destroyFramebuffer(vk_device, fb, null);

        tracker.buffers.deinit(allocator);
        tracker.textures.deinit(allocator);
        tracker.texture_views.deinit(allocator);
        tracker.bind_groups.deinit(allocator);
        tracker.compute_pipelines.deinit(allocator);
        tracker.render_pipelines.deinit(allocator);
        tracker.upload_pages.deinit(allocator);
        tracker.framebuffers.deinit(allocator);
        allocator.destroy(tracker);
    }

    pub fn referenceBuffer(tracker: *ReferenceTracker, buffer: *Buffer) !void {
        buffer.manager.reference();
        try tracker.buffers.append(allocator, buffer);
    }

    pub fn referenceTexture(tracker: *ReferenceTracker, texture: *Texture) !void {
        texture.manager.reference();
        try tracker.textures.append(allocator, texture);
    }

    pub fn referenceTextureView(tracker: *ReferenceTracker, texture_view: *TextureView) !void {
        texture_view.manager.reference();
        try tracker.texture_views.append(allocator, texture_view);
    }

    pub fn referenceBindGroup(tracker: *ReferenceTracker, group: *BindGroup) !void {
        group.manager.reference();
        try tracker.bind_groups.append(allocator, group);
    }

    pub fn referenceComputePipeline(tracker: *ReferenceTracker, pipeline: *ComputePipeline) !void {
        pipeline.manager.reference();
        try tracker.compute_pipelines.append(allocator, pipeline);
    }

    pub fn referenceRenderPipeline(tracker: *ReferenceTracker, pipeline: *RenderPipeline) !void {
        pipeline.manager.reference();
        try tracker.render_pipelines.append(allocator, pipeline);
    }

    pub fn referenceUploadPage(tracker: *ReferenceTracker, upload_page: *Buffer) !void {
        try tracker.upload_pages.append(allocator, upload_page);
    }

    pub fn submit(tracker: *ReferenceTracker) !void {
        for (tracker.buffers.items) |buffer| {
            buffer.gpu_count += 1;
        }

        for (tracker.bind_groups.items) |group| {
            for (group.buffers.items) |access| access.buffer.gpu_count += 1;
        }
    }
};

pub const CommandEncoder = struct {
    manager: utils.Manager(CommandEncoder) = .{},
    device: *Device,
    command_buffer: *CommandBuffer,
    reference_tracker: *ReferenceTracker,
    state_tracker: StateTracker = .{},

    pub fn init(device: *Device, desc: ?*const sysgpu.CommandEncoder.Descriptor) !*CommandEncoder {
        _ = desc;

        const command_buffer = try CommandBuffer.init(device);

        const cmd_encoder = try allocator.create(CommandEncoder);
        cmd_encoder.* = .{
            .device = device,
            .command_buffer = command_buffer,
            .reference_tracker = command_buffer.reference_tracker,
        };
        return cmd_encoder;
    }

    pub fn deinit(cmd_encoder: *CommandEncoder) void {
        cmd_encoder.state_tracker.deinit();
        cmd_encoder.command_buffer.manager.release();
        allocator.destroy(cmd_encoder);
    }

    pub fn beginComputePass(encoder: *CommandEncoder, desc: *const sysgpu.ComputePassDescriptor) !*ComputePassEncoder {
        return ComputePassEncoder.init(encoder, desc);
    }

    pub fn beginRenderPass(encoder: *CommandEncoder, desc: *const sysgpu.RenderPassDescriptor) !*RenderPassEncoder {
        try encoder.state_tracker.endPass();
        return RenderPassEncoder.init(encoder, desc);
    }

    pub fn copyBufferToBuffer(
        encoder: *CommandEncoder,
        source: *Buffer,
        source_offset: u64,
        destination: *Buffer,
        destination_offset: u64,
        size: u64,
    ) !void {
        const vk_command_buffer = encoder.command_buffer.vk_command_buffer;

        try encoder.reference_tracker.referenceBuffer(source);
        try encoder.reference_tracker.referenceBuffer(destination);
        try encoder.state_tracker.copyFromBuffer(source);
        try encoder.state_tracker.writeToBuffer(destination, .{ .transfer_bit = true }, .{ .transfer_write_bit = true });
        encoder.state_tracker.flush(vk_command_buffer);

        const region = vk.BufferCopy{
            .src_offset = source_offset,
            .dst_offset = destination_offset,
            .size = size,
        };
        vkd.cmdCopyBuffer(vk_command_buffer, source.vk_buffer, destination.vk_buffer, 1, @ptrCast(&region));
    }

    pub fn copyBufferToTexture(
        encoder: *CommandEncoder,
        source: *const sysgpu.ImageCopyBuffer,
        destination: *const sysgpu.ImageCopyTexture,
        copy_size_raw: *const sysgpu.Extent3D,
    ) !void {
        const vk_command_buffer = encoder.command_buffer.vk_command_buffer;
        const source_buffer: *Buffer = @ptrCast(@alignCast(source.buffer));
        const destination_texture: *Texture = @ptrCast(@alignCast(destination.texture));

        try encoder.reference_tracker.referenceBuffer(source_buffer);
        try encoder.reference_tracker.referenceTexture(destination_texture);
        try encoder.state_tracker.copyFromBuffer(source_buffer);
        try encoder.state_tracker.writeToTexture(
            destination_texture,
            .{ .transfer_bit = true },
            .{ .transfer_write_bit = true },
            .transfer_dst_optimal,
        );
        encoder.state_tracker.flush(vk_command_buffer);

        const copy_size = utils.calcExtent(destination_texture.dimension, copy_size_raw.*);
        const destination_origin = utils.calcOrigin(destination_texture.dimension, destination.origin);

        const region = vk.BufferImageCopy{
            .buffer_offset = source.layout.offset,
            .buffer_row_length = source.layout.bytes_per_row / 4, // TODO
            .buffer_image_height = source.layout.rows_per_image,
            .image_subresource = .{
                .aspect_mask = conv.vulkanImageAspectFlags(destination.aspect, destination_texture.format),
                .mip_level = destination.mip_level,
                .base_array_layer = destination_origin.array_slice,
                .layer_count = copy_size.array_count,
            },
            .image_offset = .{
                .x = @intCast(destination_origin.x),
                .y = @intCast(destination_origin.y),
                .z = @intCast(destination_origin.z),
            },
            .image_extent = .{ .width = copy_size.width, .height = copy_size.height, .depth = copy_size.depth },
        };

        vkd.cmdCopyBufferToImage(
            vk_command_buffer,
            source_buffer.vk_buffer,
            destination_texture.image,
            .transfer_dst_optimal,
            1,
            @ptrCast(&region),
        );
    }

    pub fn copyTextureToTexture(
        encoder: *CommandEncoder,
        source: *const sysgpu.ImageCopyTexture,
        destination: *const sysgpu.ImageCopyTexture,
        copy_size_raw: *const sysgpu.Extent3D,
    ) !void {
        const vk_command_buffer = encoder.command_buffer.vk_command_buffer;
        const source_texture: *Texture = @ptrCast(@alignCast(source.texture));
        const destination_texture: *Texture = @ptrCast(@alignCast(destination.texture));

        try encoder.reference_tracker.referenceTexture(source_texture);
        try encoder.reference_tracker.referenceTexture(destination_texture);
        try encoder.state_tracker.copyFromTexture(source_texture);
        try encoder.state_tracker.writeToTexture(
            destination_texture,
            .{ .transfer_bit = true },
            .{ .transfer_write_bit = true },
            .transfer_dst_optimal,
        );
        encoder.state_tracker.flush(vk_command_buffer);

        const copy_size = utils.calcExtent(destination_texture.dimension, copy_size_raw.*);
        const source_origin = utils.calcOrigin(source_texture.dimension, source.origin);
        const destination_origin = utils.calcOrigin(destination_texture.dimension, destination.origin);

        const region = vk.ImageCopy{
            .src_subresource = .{
                .aspect_mask = conv.vulkanImageAspectFlags(source.aspect, source_texture.format),
                .mip_level = source.mip_level,
                .base_array_layer = source_origin.array_slice,
                .layer_count = copy_size.array_count,
            },
            .src_offset = .{
                .x = @intCast(source_origin.x),
                .y = @intCast(source_origin.y),
                .z = @intCast(source_origin.z),
            },
            .dst_subresource = .{
                .aspect_mask = conv.vulkanImageAspectFlags(destination.aspect, destination_texture.format),
                .mip_level = destination.mip_level,
                .base_array_layer = destination_origin.array_slice,
                .layer_count = copy_size.array_count,
            },
            .dst_offset = .{
                .x = @intCast(destination_origin.x),
                .y = @intCast(destination_origin.y),
                .z = @intCast(destination_origin.z),
            },
            .extent = .{ .width = copy_size.width, .height = copy_size.height, .depth = copy_size.depth },
        };

        vkd.cmdCopyImage(
            vk_command_buffer,
            source_texture.image,
            .transfer_src_optimal,
            destination_texture.image,
            .transfer_dst_optimal,
            1,
            @ptrCast(&region),
        );
    }

    pub fn finish(encoder: *CommandEncoder, desc: *const sysgpu.CommandBuffer.Descriptor) !*CommandBuffer {
        _ = desc;
        const vk_command_buffer = encoder.command_buffer.vk_command_buffer;

        try encoder.state_tracker.endPass();
        encoder.state_tracker.flush(vk_command_buffer);

        try vkd.endCommandBuffer(vk_command_buffer);
        return encoder.command_buffer;
    }

    pub fn writeBuffer(encoder: *CommandEncoder, buffer: *Buffer, offset: u64, data: [*]const u8, size: u64) !void {
        const stream = try encoder.command_buffer.upload(size);
        @memcpy(stream.map[0..size], data[0..size]);

        try encoder.copyBufferToBuffer(stream.buffer, stream.offset, buffer, offset, size);
    }

    pub fn writeTexture(
        encoder: *CommandEncoder,
        destination: *const sysgpu.ImageCopyTexture,
        data: [*]const u8,
        data_size: usize,
        data_layout: *const sysgpu.Texture.DataLayout,
        write_size: *const sysgpu.Extent3D,
    ) !void {
        const stream = try encoder.command_buffer.upload(data_size);
        @memcpy(stream.map[0..data_size], data[0..data_size]);

        try encoder.copyBufferToTexture(
            &.{
                .layout = .{
                    .offset = stream.offset,
                    .bytes_per_row = data_layout.bytes_per_row,
                    .rows_per_image = data_layout.rows_per_image,
                },
                .buffer = @ptrCast(stream.buffer),
            },
            destination,
            write_size,
        );
    }
};

pub const StateTracker = struct {
    const BufferState = struct {
        stage_mask: vk.PipelineStageFlags,
        access_mask: vk.AccessFlags,
    };
    const TextureState = struct {
        stage_mask: vk.PipelineStageFlags,
        access_mask: vk.AccessFlags,
        image_layout: vk.ImageLayout,
    };

    device: *Device = undefined,
    written_buffers: std.AutoHashMapUnmanaged(*Buffer, BufferState) = .{},
    copy_buffers: std.AutoHashMapUnmanaged(*Buffer, void) = .{},
    written_textures: std.AutoHashMapUnmanaged(*Texture, TextureState) = .{},
    copy_textures: std.AutoHashMapUnmanaged(*Texture, void) = .{},
    image_barriers: std.ArrayListUnmanaged(vk.ImageMemoryBarrier) = .{},
    src_stage_mask: vk.PipelineStageFlags = .{},
    dst_stage_mask: vk.PipelineStageFlags = .{},
    src_access_mask: vk.AccessFlags = .{},
    dst_access_mask: vk.AccessFlags = .{},

    pub fn init(tracker: *StateTracker, device: *Device) void {
        tracker.device = device;
    }

    pub fn deinit(tracker: *StateTracker) void {
        tracker.written_buffers.deinit(allocator);
        tracker.copy_buffers.deinit(allocator);
        tracker.written_textures.deinit(allocator);
        tracker.copy_textures.deinit(allocator);
        tracker.image_barriers.deinit(allocator);
    }

    pub fn accessBindGroup(
        tracker: *StateTracker,
        group: *BindGroup,
        stage_mask: vk.PipelineStageFlags,
        access_mask: vk.AccessFlags,
        image_layout: vk.ImageLayout,
    ) !void {
        for (group.buffers.items) |access| {
            const buffer = access.buffer;
            if (access.storage) {
                try tracker.writeToBuffer(buffer, stage_mask, access_mask);
            } else {
                try tracker.readFromBuffer(buffer);
            }
        }
        for (group.texture_views.items) |access| {
            const texture = access.texture_view.texture;
            if (access.storage) {
                try tracker.writeToTexture(texture, stage_mask, access_mask, image_layout);
            } else {
                try tracker.readFromTexture(texture);
            }
        }
    }

    pub fn writeToBuffer(
        tracker: *StateTracker,
        buffer: *Buffer,
        stage_mask: vk.PipelineStageFlags,
        access_mask: vk.AccessFlags,
    ) !void {
        if (tracker.written_buffers.fetchRemove(buffer)) |write| {
            // WAW hazard
            tracker.src_stage_mask = tracker.src_stage_mask.merge(write.value.stage_mask);
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);

            tracker.src_access_mask = tracker.src_access_mask.merge(write.value.access_mask);
            tracker.dst_access_mask = tracker.dst_access_mask.merge(access_mask);
        } else if (tracker.copy_buffers.fetchRemove(buffer)) |_| {
            // WAR hazard
            tracker.src_stage_mask = tracker.src_stage_mask.merge(.{ .transfer_bit = true });
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);
        } else {
            // WAR hazard
            tracker.src_stage_mask = tracker.src_stage_mask.merge(buffer.read_stage_mask);
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);
        }

        try tracker.written_buffers.put(allocator, buffer, .{ .stage_mask = stage_mask, .access_mask = access_mask });
    }

    pub fn writeToTexture(
        tracker: *StateTracker,
        texture: *Texture,
        stage_mask: vk.PipelineStageFlags,
        access_mask: vk.AccessFlags,
        image_layout: vk.ImageLayout,
    ) !void {
        var src_access_mask: vk.AccessFlags = undefined;
        var old_layout: vk.ImageLayout = undefined;
        if (tracker.written_textures.fetchRemove(texture)) |write| {
            // WAW hazard
            tracker.src_stage_mask = tracker.src_stage_mask.merge(write.value.stage_mask);
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);

            src_access_mask = write.value.access_mask;
            old_layout = write.value.image_layout;
        } else if (tracker.copy_textures.fetchRemove(texture)) |_| {
            // WAR hazard
            tracker.src_stage_mask = tracker.src_stage_mask.merge(.{ .transfer_bit = true });
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);

            src_access_mask = .{};
            old_layout = .transfer_src_optimal;
        } else {
            // WAR hazard
            tracker.src_stage_mask = tracker.src_stage_mask.merge(texture.read_stage_mask);
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);

            src_access_mask = .{};
            old_layout = texture.read_image_layout;
        }

        if (old_layout != image_layout) {
            try tracker.addImageBarrier(texture, src_access_mask, access_mask, old_layout, image_layout);
        }

        try tracker.written_textures.put(
            allocator,
            texture,
            .{ .stage_mask = stage_mask, .access_mask = access_mask, .image_layout = image_layout },
        );
    }

    pub fn readFromBufferEx(
        tracker: *StateTracker,
        buffer: *Buffer,
        stage_mask: vk.PipelineStageFlags,
        access_mask: vk.AccessFlags,
    ) !void {
        if (tracker.written_buffers.fetchRemove(buffer)) |write| {
            // RAW hazard
            tracker.src_stage_mask = tracker.src_stage_mask.merge(write.value.stage_mask);
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);

            tracker.src_access_mask = tracker.src_access_mask.merge(write.value.access_mask);
            tracker.dst_access_mask = tracker.dst_access_mask.merge(access_mask);
        } else if (tracker.copy_buffers.fetchRemove(buffer)) |_| {
            // RAR hazard - no hazard
        }
    }

    pub fn readFromBuffer(tracker: *StateTracker, buffer: *Buffer) !void {
        try tracker.readFromBufferEx(buffer, buffer.read_stage_mask, buffer.read_access_mask);
    }

    pub fn copyFromBuffer(tracker: *StateTracker, buffer: *Buffer) !void {
        try tracker.readFromBufferEx(buffer, .{ .transfer_bit = true }, .{ .transfer_read_bit = true });
        try tracker.copy_buffers.put(allocator, buffer, {});
    }

    pub fn readFromTextureEx(
        tracker: *StateTracker,
        texture: *Texture,
        stage_mask: vk.PipelineStageFlags,
        access_mask: vk.AccessFlags,
        image_layout: vk.ImageLayout,
    ) !void {
        var src_access_mask: vk.AccessFlags = undefined;
        var old_layout: vk.ImageLayout = undefined;
        if (tracker.written_textures.fetchRemove(texture)) |write| {
            // RAW hazard
            tracker.src_stage_mask = tracker.src_stage_mask.merge(write.value.stage_mask);
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);

            src_access_mask = write.value.access_mask;
            old_layout = write.value.image_layout;
        } else if (tracker.copy_textures.fetchRemove(texture)) |_| {
            // RAR - no execution hazard but needed for layout transition
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);

            src_access_mask = .{};
            old_layout = .transfer_src_optimal;
        } else {
            // RAR - no hazard
            tracker.dst_stage_mask = tracker.dst_stage_mask.merge(stage_mask);

            src_access_mask = .{};
            old_layout = texture.read_image_layout;
        }

        if (old_layout != image_layout) {
            try tracker.addImageBarrier(texture, src_access_mask, access_mask, old_layout, image_layout);
        }
    }

    pub fn readFromTexture(tracker: *StateTracker, texture: *Texture) !void {
        try tracker.readFromTextureEx(texture, texture.read_stage_mask, texture.read_access_mask, texture.read_image_layout);
    }

    pub fn copyFromTexture(tracker: *StateTracker, texture: *Texture) !void {
        try tracker.readFromTextureEx(texture, .{ .transfer_bit = true }, .{ .transfer_read_bit = true }, .transfer_src_optimal);
        try tracker.copy_textures.put(allocator, texture, {});
    }

    pub fn initTexture(tracker: *StateTracker, texture: *Texture) !void {
        const src_access_mask = .{};
        const old_layout = .undefined;
        const access_mask = texture.read_access_mask;
        const image_layout = texture.read_image_layout;
        tracker.dst_stage_mask = tracker.dst_stage_mask.merge(texture.read_stage_mask);

        try tracker.addImageBarrier(texture, src_access_mask, access_mask, old_layout, image_layout);
    }

    pub fn flush(tracker: *StateTracker, vk_command_buffer: vk.CommandBuffer) void {
        if (tracker.src_stage_mask.merge(tracker.dst_stage_mask).toInt() == 0 and
            tracker.image_barriers.items.len == 0)
            return;

        var memory_barriers = std.BoundedArray(vk.MemoryBarrier, 1){};
        if (tracker.src_access_mask.merge(tracker.dst_access_mask).toInt() != 0) {
            memory_barriers.appendAssumeCapacity(.{
                .src_access_mask = tracker.src_access_mask,
                .dst_access_mask = tracker.dst_access_mask,
            });
        }

        // If the synchronization2 feature is not enabled, srcStageMask must not be 0
        const src_stage_mask = if (tracker.src_stage_mask.toInt() != 0)
            tracker.src_stage_mask
        else
            vk.PipelineStageFlags{ .top_of_pipe_bit = true };

        vkd.cmdPipelineBarrier(
            vk_command_buffer,
            src_stage_mask,
            tracker.dst_stage_mask,
            .{},
            @intCast(memory_barriers.len),
            &memory_barriers.buffer,
            0,
            null,
            @intCast(tracker.image_barriers.items.len),
            tracker.image_barriers.items.ptr,
        );

        tracker.src_stage_mask = .{};
        tracker.dst_stage_mask = .{};
        tracker.src_access_mask = .{};
        tracker.dst_access_mask = .{};
        tracker.image_barriers.clearRetainingCapacity();
    }

    pub fn endPass(tracker: *StateTracker) !void {
        {
            var it = tracker.written_buffers.iterator();
            while (it.next()) |entry| {
                const buffer = entry.key_ptr.*;
                const write = entry.value_ptr.*;

                tracker.src_stage_mask = tracker.src_stage_mask.merge(write.stage_mask);
                tracker.dst_stage_mask = tracker.dst_stage_mask.merge(buffer.read_stage_mask);

                tracker.src_access_mask = tracker.src_access_mask.merge(write.access_mask);
                tracker.dst_access_mask = tracker.dst_access_mask.merge(buffer.read_access_mask);
            }
            tracker.written_buffers.clearRetainingCapacity();
        }

        {
            // no hazard
            tracker.copy_buffers.clearRetainingCapacity();
        }

        {
            var it = tracker.written_textures.iterator();
            while (it.next()) |entry| {
                const texture = entry.key_ptr.*;
                const write = entry.value_ptr.*;

                tracker.src_stage_mask = tracker.src_stage_mask.merge(write.stage_mask);
                tracker.dst_stage_mask = tracker.dst_stage_mask.merge(texture.read_stage_mask);

                const src_access_mask = write.access_mask;
                const old_layout = write.image_layout;
                const access_mask = texture.read_access_mask;
                const image_layout = texture.read_image_layout;

                if (old_layout != image_layout) {
                    try tracker.addImageBarrier(texture, src_access_mask, access_mask, old_layout, image_layout);
                }
            }
            tracker.written_textures.clearRetainingCapacity();
        }

        {
            var it = tracker.copy_textures.iterator();
            while (it.next()) |entry| {
                const texture = entry.key_ptr.*;

                const src_access_mask: vk.AccessFlags = .{};
                const old_layout: vk.ImageLayout = .transfer_src_optimal;
                const access_mask = texture.read_access_mask;
                const image_layout = texture.read_image_layout;

                if (old_layout != image_layout) {
                    try tracker.addImageBarrier(texture, src_access_mask, access_mask, old_layout, image_layout);
                }
            }
            tracker.copy_textures.clearRetainingCapacity();
        }
    }

    fn addImageBarrier(
        tracker: *StateTracker,
        texture: *Texture,
        src_access_mask: vk.AccessFlags,
        dst_access_mask: vk.AccessFlags,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
    ) !void {
        const size = utils.calcExtent(texture.dimension, texture.size);

        try tracker.image_barriers.append(allocator, .{
            .src_access_mask = src_access_mask,
            .dst_access_mask = dst_access_mask,
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = texture.image,
            .subresource_range = .{
                .aspect_mask = conv.vulkanImageAspectFlags(.all, texture.format),
                .base_mip_level = 0,
                .level_count = texture.mip_level_count,
                .base_array_layer = 0,
                .layer_count = size.array_count,
            },
        });
    }
};

pub const ComputePassEncoder = struct {
    manager: utils.Manager(ComputePassEncoder) = .{},
    vk_command_buffer: vk.CommandBuffer,
    reference_tracker: *ReferenceTracker,
    state_tracker: *StateTracker,
    pipeline: ?*ComputePipeline = null,
    bind_groups: [limits.max_bind_groups]*BindGroup = undefined,

    pub fn init(cmd_encoder: *CommandEncoder, desc: *const sysgpu.ComputePassDescriptor) !*ComputePassEncoder {
        _ = desc;
        const vk_command_buffer = cmd_encoder.command_buffer.vk_command_buffer;

        const encoder = try allocator.create(ComputePassEncoder);
        encoder.* = .{
            .vk_command_buffer = vk_command_buffer,
            .reference_tracker = cmd_encoder.reference_tracker,
            .state_tracker = &cmd_encoder.state_tracker,
        };
        return encoder;
    }

    pub fn deinit(encoder: *ComputePassEncoder) void {
        allocator.destroy(encoder);
    }

    pub fn dispatchWorkgroups(
        encoder: *ComputePassEncoder,
        workgroup_count_x: u32,
        workgroup_count_y: u32,
        workgroup_count_z: u32,
    ) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        const bind_group_count = encoder.pipeline.?.layout.group_layouts.len;
        for (encoder.bind_groups[0..bind_group_count]) |group| {
            try encoder.state_tracker.accessBindGroup(
                group,
                .{ .compute_shader_bit = true },
                .{ .shader_write_bit = true },
                .general,
            );
        }
        encoder.state_tracker.flush(vk_command_buffer);

        vkd.cmdDispatch(vk_command_buffer, workgroup_count_x, workgroup_count_y, workgroup_count_z);
    }

    pub fn end(encoder: *ComputePassEncoder) void {
        _ = encoder;
    }

    pub fn setBindGroup(
        encoder: *ComputePassEncoder,
        group_index: u32,
        group: *BindGroup,
        dynamic_offset_count: usize,
        dynamic_offsets: ?[*]const u32,
    ) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        try encoder.reference_tracker.referenceBindGroup(group);
        encoder.bind_groups[group_index] = group;

        vkd.cmdBindDescriptorSets(
            vk_command_buffer,
            .compute,
            encoder.pipeline.?.layout.vk_layout,
            group_index,
            1,
            @ptrCast(&group.desc_set),
            @intCast(dynamic_offset_count),
            if (dynamic_offsets) |offsets| offsets else &[_]u32{},
        );
    }

    pub fn setPipeline(encoder: *ComputePassEncoder, pipeline: *ComputePipeline) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        try encoder.reference_tracker.referenceComputePipeline(pipeline);

        vkd.cmdBindPipeline(
            vk_command_buffer,
            .compute,
            pipeline.vk_pipeline,
        );

        encoder.pipeline = pipeline;
    }
};

pub const RenderPassEncoder = struct {
    manager: utils.Manager(RenderPassEncoder) = .{},
    device: *Device,
    encoder: *CommandEncoder,
    vk_command_buffer: vk.CommandBuffer,
    reference_tracker: *ReferenceTracker,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    extent: vk.Extent2D,
    pipeline: ?*RenderPipeline = null,

    pub fn init(cmd_encoder: *CommandEncoder, desc: *const sysgpu.RenderPassDescriptor) !*RenderPassEncoder {
        const device = cmd_encoder.device;
        const vk_device = device.vk_device;
        const vk_command_buffer = cmd_encoder.command_buffer.vk_command_buffer;

        const depth_stencil_attachment_count = @intFromBool(desc.depth_stencil_attachment != null);
        const max_attachment_count = 2 * (desc.color_attachment_count + depth_stencil_attachment_count);

        var image_views = try std.ArrayList(vk.ImageView).initCapacity(allocator, max_attachment_count);
        defer image_views.deinit();

        var clear_values = std.ArrayList(vk.ClearValue).init(allocator);
        defer clear_values.deinit();

        var rp_key = Device.RenderPassKey.init();
        var extent: vk.Extent2D = .{ .width = 0, .height = 0 };

        for (0..desc.color_attachment_count) |i| {
            const attach = desc.color_attachments.?[i];
            if (attach.view) |view_raw| {
                const view: *TextureView = @ptrCast(@alignCast(view_raw));
                const resolve_view: ?*TextureView = @ptrCast(@alignCast(attach.resolve_target));

                try cmd_encoder.reference_tracker.referenceTextureView(view);
                if (resolve_view) |v|
                    try cmd_encoder.reference_tracker.referenceTextureView(v);

                if (use_semaphore_wait) {
                    if (view.texture.swapchain) |sc| {
                        try cmd_encoder.command_buffer.wait_semaphores.append(allocator, sc.wait_semaphore);
                        try cmd_encoder.command_buffer.wait_dst_stage_masks.append(allocator, .{ .all_commands_bit = true });
                    }
                }

                image_views.appendAssumeCapacity(view.vk_view);
                if (resolve_view) |rv|
                    image_views.appendAssumeCapacity(rv.vk_view);

                rp_key.colors.appendAssumeCapacity(.{
                    .format = view.vk_format,
                    .samples = view.texture.sample_count,
                    .load_op = attach.load_op,
                    .store_op = attach.store_op,
                    .layout = view.texture.read_image_layout,
                    .resolve = if (resolve_view) |rv| .{
                        .format = rv.vk_format,
                        .layout = rv.texture.read_image_layout,
                    } else null,
                });

                try clear_values.append(.{
                    .color = .{
                        .float_32 = [4]f32{
                            @floatCast(attach.clear_value.r),
                            @floatCast(attach.clear_value.g),
                            @floatCast(attach.clear_value.b),
                            @floatCast(attach.clear_value.a),
                        },
                    },
                });

                extent = view.extent;
            }
        }

        if (desc.depth_stencil_attachment) |attach| {
            const view: *TextureView = @ptrCast(@alignCast(attach.view));

            try cmd_encoder.reference_tracker.referenceTextureView(view);

            image_views.appendAssumeCapacity(view.vk_view);

            rp_key.depth_stencil = .{
                .format = view.vk_format,
                .samples = view.texture.sample_count,
                .depth_load_op = attach.depth_load_op,
                .depth_store_op = attach.depth_store_op,
                .stencil_load_op = attach.stencil_load_op,
                .stencil_store_op = attach.stencil_store_op,
                .layout = view.texture.read_image_layout,
                .read_only = attach.depth_read_only == .true or attach.stencil_read_only == .true,
            };

            try clear_values.append(.{
                .depth_stencil = .{
                    .depth = attach.depth_clear_value,
                    .stencil = attach.stencil_clear_value,
                },
            });

            extent = view.extent;
        }

        const render_pass = try device.createRenderPass(rp_key);
        const framebuffer = try vkd.createFramebuffer(vk_device, &.{
            .render_pass = render_pass,
            .attachment_count = @as(u32, @intCast(image_views.items.len)),
            .p_attachments = image_views.items.ptr,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        }, null);
        try cmd_encoder.reference_tracker.framebuffers.append(allocator, framebuffer);

        cmd_encoder.state_tracker.flush(vk_command_buffer);

        const rect = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };

        vkd.cmdBeginRenderPass(vk_command_buffer, &vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .render_area = rect,
            .clear_value_count = @as(u32, @intCast(clear_values.items.len)),
            .p_clear_values = clear_values.items.ptr,
        }, .@"inline");

        vkd.cmdSetViewport(vk_command_buffer, 0, 1, @as(*const [1]vk.Viewport, &vk.Viewport{
            .x = 0,
            .y = @as(f32, @floatFromInt(extent.height)),
            .width = @as(f32, @floatFromInt(extent.width)),
            .height = -@as(f32, @floatFromInt(extent.height)),
            .min_depth = 0,
            .max_depth = 1,
        }));

        vkd.cmdSetScissor(vk_command_buffer, 0, 1, @as(*const [1]vk.Rect2D, &rect));
        vkd.cmdSetStencilReference(vk_command_buffer, .{ .front_bit = true, .back_bit = true }, 0);

        // Result
        const rpe = try allocator.create(RenderPassEncoder);
        errdefer allocator.destroy(rpe);
        rpe.* = .{
            .device = device,
            .encoder = cmd_encoder,
            .vk_command_buffer = vk_command_buffer,
            .reference_tracker = cmd_encoder.reference_tracker,
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .extent = extent,
        };

        return rpe;
    }

    pub fn deinit(encoder: *RenderPassEncoder) void {
        allocator.destroy(encoder);
    }

    pub fn draw(
        encoder: *RenderPassEncoder,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        vkd.cmdDraw(vk_command_buffer, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexed(
        encoder: *RenderPassEncoder,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: i32,
        first_instance: u32,
    ) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        vkd.cmdDrawIndexed(vk_command_buffer, index_count, instance_count, first_index, base_vertex, first_instance);
    }

    pub fn setBindGroup(
        encoder: *RenderPassEncoder,
        group_index: u32,
        group: *BindGroup,
        dynamic_offset_count: usize,
        dynamic_offsets: ?[*]const u32,
    ) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        try encoder.reference_tracker.referenceBindGroup(group);

        vkd.cmdBindDescriptorSets(
            vk_command_buffer,
            .graphics,
            encoder.pipeline.?.layout.vk_layout,
            group_index,
            1,
            @ptrCast(&group.desc_set),
            @intCast(dynamic_offset_count),
            if (dynamic_offsets) |offsets| offsets else &[_]u32{},
        );
    }

    pub fn end(encoder: *RenderPassEncoder) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        vkd.cmdEndRenderPass(vk_command_buffer);
    }

    pub fn setIndexBuffer(
        encoder: *RenderPassEncoder,
        buffer: *Buffer,
        format: sysgpu.IndexFormat,
        offset: u64,
        size: u64,
    ) !void {
        _ = size;
        const vk_command_buffer = encoder.vk_command_buffer;

        try encoder.reference_tracker.referenceBuffer(buffer);

        vkd.cmdBindIndexBuffer(vk_command_buffer, buffer.vk_buffer, offset, conv.vulkanIndexType(format));
    }

    pub fn setPipeline(encoder: *RenderPassEncoder, pipeline: *RenderPipeline) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        try encoder.reference_tracker.referenceRenderPipeline(pipeline);

        vkd.cmdBindPipeline(vk_command_buffer, .graphics, pipeline.vk_pipeline);

        encoder.pipeline = pipeline;
    }

    pub fn setScissorRect(encoder: *RenderPassEncoder, x: u32, y: u32, width: u32, height: u32) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        const rect = vk.Rect2D{
            .offset = .{ .x = @intCast(x), .y = @intCast(y) },
            .extent = .{ .width = width, .height = height },
        };

        vkd.cmdSetScissor(vk_command_buffer, 0, 1, @as(*const [1]vk.Rect2D, &rect));
    }

    pub fn setVertexBuffer(encoder: *RenderPassEncoder, slot: u32, buffer: *Buffer, offset: u64, size: u64) !void {
        _ = size;
        const vk_command_buffer = encoder.vk_command_buffer;

        try encoder.reference_tracker.referenceBuffer(buffer);

        vkd.cmdBindVertexBuffers(vk_command_buffer, slot, 1, @ptrCast(&.{buffer.vk_buffer}), @ptrCast(&offset));
    }

    pub fn setViewport(
        encoder: *RenderPassEncoder,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        min_depth: f32,
        max_depth: f32,
    ) !void {
        const vk_command_buffer = encoder.vk_command_buffer;

        vkd.cmdSetViewport(vk_command_buffer, 0, 1, @as(*const [1]vk.Viewport, &vk.Viewport{
            .x = x,
            .y = @as(f32, @floatFromInt(encoder.extent.height)) - y,
            .width = width,
            .height = -height,
            .min_depth = min_depth,
            .max_depth = max_depth,
        }));
    }
};

pub const Queue = struct {
    manager: utils.Manager(Queue) = .{},
    device: *Device,
    vk_queue: vk.Queue,
    command_buffers: std.ArrayListUnmanaged(*CommandBuffer) = .{},
    wait_semaphores: std.ArrayListUnmanaged(vk.Semaphore) = .{},
    wait_dst_stage_masks: std.ArrayListUnmanaged(vk.PipelineStageFlags) = .{},
    signal_semaphores: std.ArrayListUnmanaged(vk.Semaphore) = .{},
    command_encoder: ?*CommandEncoder = null,

    pub fn init(device: *Device) !Queue {
        const vk_device = device.vk_device;

        const vk_queue = vkd.getDeviceQueue(vk_device, device.adapter.queue_family, 0);

        return .{
            .device = device,
            .vk_queue = vk_queue,
        };
    }

    pub fn deinit(queue: *Queue) void {
        if (queue.command_encoder) |command_encoder| command_encoder.manager.release();
        queue.wait_dst_stage_masks.deinit(allocator);
        queue.wait_semaphores.deinit(allocator);
        queue.signal_semaphores.deinit(allocator);
        queue.command_buffers.deinit(allocator);
    }

    pub fn submit(queue: *Queue, commands: []const *CommandBuffer) !void {
        if (queue.command_encoder) |command_encoder| {
            const command_buffer = try command_encoder.finish(&.{});
            command_buffer.manager.reference(); // handled in main.zig
            defer command_buffer.manager.release();

            command_buffer.manager.reference();
            try queue.command_buffers.append(allocator, command_buffer);
            try command_buffer.reference_tracker.submit();

            command_encoder.manager.release();
            queue.command_encoder = null;
        }

        for (commands) |command_buffer| {
            command_buffer.manager.reference();
            try queue.command_buffers.append(allocator, command_buffer);
            try command_buffer.reference_tracker.submit();

            try queue.wait_dst_stage_masks.appendSlice(allocator, command_buffer.wait_dst_stage_masks.items);
            try queue.wait_semaphores.appendSlice(allocator, command_buffer.wait_semaphores.items);
        }
    }

    pub fn flush(queue: *Queue) !void {
        if (queue.command_buffers.items.len == 0 and
            queue.signal_semaphores.items.len == 0)
            return;

        const vk_queue = queue.vk_queue;

        var submit_object = try SubmitObject.init(queue.device);
        var vk_command_buffers = try std.ArrayListUnmanaged(vk.CommandBuffer).initCapacity(
            allocator,
            queue.command_buffers.items.len,
        );
        defer vk_command_buffers.deinit(allocator);

        for (queue.command_buffers.items) |command_buffer| {
            vk_command_buffers.appendAssumeCapacity(command_buffer.vk_command_buffer);
            try submit_object.reference_trackers.append(allocator, command_buffer.reference_tracker);
            command_buffer.manager.release();
        }
        queue.command_buffers.clearRetainingCapacity();

        const submitInfo = vk.SubmitInfo{
            .command_buffer_count = @intCast(vk_command_buffers.items.len),
            .p_command_buffers = vk_command_buffers.items.ptr,
            .wait_semaphore_count = @intCast(queue.wait_semaphores.items.len),
            .p_wait_semaphores = queue.wait_semaphores.items.ptr,
            .p_wait_dst_stage_mask = queue.wait_dst_stage_masks.items.ptr,
            .signal_semaphore_count = @intCast(queue.signal_semaphores.items.len),
            .p_signal_semaphores = queue.signal_semaphores.items.ptr,
        };

        try vkd.queueSubmit(vk_queue, 1, @ptrCast(&submitInfo), submit_object.fence);

        queue.wait_semaphores.clearRetainingCapacity();
        queue.wait_dst_stage_masks.clearRetainingCapacity();
        queue.signal_semaphores.clearRetainingCapacity();

        try queue.device.submit_objects.append(allocator, submit_object);
    }

    pub fn writeBuffer(queue: *Queue, buffer: *Buffer, offset: u64, data: [*]const u8, size: u64) !void {
        const encoder = try queue.getCommandEncoder();
        try encoder.writeBuffer(buffer, offset, data, size);
    }

    pub fn writeTexture(
        queue: *Queue,
        destination: *const sysgpu.ImageCopyTexture,
        data: [*]const u8,
        data_size: usize,
        data_layout: *const sysgpu.Texture.DataLayout,
        write_size: *const sysgpu.Extent3D,
    ) !void {
        const encoder = try queue.getCommandEncoder();
        try encoder.writeTexture(destination, data, data_size, data_layout, write_size);
    }

    // Private
    fn getCommandEncoder(queue: *Queue) !*CommandEncoder {
        if (queue.command_encoder) |command_encoder| return command_encoder;

        const command_encoder = try CommandEncoder.init(queue.device, &.{});
        queue.command_encoder = command_encoder;
        return command_encoder;
    }
};

const MemoryAllocator = struct {
    info: vk.PhysicalDeviceMemoryProperties,

    const MemoryKind = enum {
        lazily_allocated,
        linear,
        linear_read_mappable,
        linear_write_mappable,
    };

    fn init(physical_device: vk.PhysicalDevice) MemoryAllocator {
        const mem_info = vki.getPhysicalDeviceMemoryProperties(physical_device);
        return .{ .info = mem_info };
    }

    fn findBestAllocator(
        mem_alloc: *MemoryAllocator,
        requirements: vk.MemoryRequirements,
        mem_kind: MemoryKind,
    ) ?u32 {
        const mem_types = mem_alloc.info.memory_types[0..mem_alloc.info.memory_type_count];
        const mem_heaps = mem_alloc.info.memory_heaps[0..mem_alloc.info.memory_heap_count];

        var best_type: ?u32 = null;
        for (mem_types, 0..) |mem_type, i| {
            if (requirements.memory_type_bits & (@as(u32, @intCast(1)) << @intCast(i)) == 0) continue;

            const flags = mem_type.property_flags;
            const heap_size = mem_heaps[mem_type.heap_index].size;
            const candidate = switch (mem_kind) {
                .lazily_allocated => flags.lazily_allocated_bit,
                .linear_write_mappable => flags.host_visible_bit and flags.host_coherent_bit and !flags.device_coherent_bit_amd,
                .linear_read_mappable => blk: {
                    if (flags.host_visible_bit and flags.host_coherent_bit and !flags.device_coherent_bit_amd) {
                        if (best_type) |best| {
                            if (mem_types[best].property_flags.host_cached_bit) {
                                if (flags.host_cached_bit) {
                                    const best_heap_size = mem_heaps[mem_types[best].heap_index].size;
                                    if (heap_size > best_heap_size) {
                                        break :blk true;
                                    }
                                }

                                break :blk false;
                            }
                        }

                        break :blk true;
                    }

                    break :blk false;
                },
                .linear => blk: {
                    if (best_type) |best| {
                        if (mem_types[best].property_flags.device_local_bit) {
                            if (flags.device_local_bit and !flags.device_coherent_bit_amd) {
                                const best_heap_size = mem_heaps[mem_types[best].heap_index].size;
                                if (heap_size > best_heap_size or flags.host_visible_bit) {
                                    break :blk true;
                                }
                            }

                            break :blk false;
                        }
                    }

                    break :blk true;
                },
            };

            if (candidate) best_type = @intCast(i);
        }

        return best_type;
    }
};

test "reference declarations" {
    std.testing.refAllDeclsRecursive(@This());
}
