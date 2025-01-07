const std = @import("std");
const mach = @import("../../main.zig");
const gpu = mach.gpu;
const Linux = @import("../Linux.zig");
const Core = @import("../../Core.zig");
const InitOptions = Core.InitOptions;
const KeyEvent = Core.KeyEvent;
const DisplayMode = Core.DisplayMode;
const log = std.log.scoped(.mach);

pub const Wayland = @This();

pub const c = @cImport({
    @cInclude("wayland-client-protocol.h");
    @cInclude("wayland-xdg-shell-client-protocol.h");
    @cInclude("wayland-xdg-decoration-client-protocol.h");
    @cInclude("wayland-viewporter-client-protocol.h");
    @cInclude("wayland-relative-pointer-unstable-v1-client-protocol.h");
    @cInclude("wayland-pointer-constraints-unstable-v1-client-protocol.h");
    @cInclude("wayland-idle-inhibit-unstable-v1-client-protocol.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-compose.h");
    @cInclude("linux/input-event-codes.h");
});

// This needs to be declared here so it can be used in the exported functions below,
// but doesn't need to be defined until run time (and can't be defined until run time).
pub var libwaylandclient: ?LibWaylandClient = null;

// This does not need to be declared here, but we are declaring it here to be consistent
// with `libwaylandclient`.
pub var libxkbcommon: ?LibXkbCommon = null;

var core_ptr: *Core = undefined;

// These exported functions are defined because the wayland headers don't define them,
// and then the linker gets confused. They reference undefined `libwaylandclient` at
// compile time, but since they are not run until run time, after `libwaylandclient` is
// defined, an error never occurs.
export fn wl_proxy_add_listener(proxy: ?*c.struct_wl_proxy, implementation: [*c]?*const fn () callconv(.C) void, data: ?*anyopaque) c_int {
    return @call(.always_tail, libwaylandclient.?.wl_proxy_add_listener, .{ proxy, implementation, data });
}
export fn wl_proxy_get_version(proxy: ?*c.struct_wl_proxy) u32 {
    return @call(.always_tail, libwaylandclient.?.wl_proxy_get_version, .{proxy});
}
export fn wl_proxy_marshal_flags(proxy: ?*c.struct_wl_proxy, opcode: u32, interface: [*c]const c.struct_wl_interface, version: u32, flags: u32, ...) ?*c.struct_wl_proxy {
    var arg_list: std.builtin.VaList = @cVaStart();
    defer @cVaEnd(&arg_list);

    return @call(.always_tail, libwaylandclient.?.wl_proxy_marshal_flags, .{ proxy, opcode, interface, version, flags, arg_list });
}
export fn wl_proxy_destroy(proxy: ?*c.struct_wl_proxy) void {
    return @call(.always_tail, libwaylandclient.?.wl_proxy_destroy, .{proxy});
}

pub const Native = struct {
    surface_descriptor: gpu.Surface.DescriptorFromWaylandSurface,
    configured: bool = false,

    display: *c.wl_display,
    surface: *c.wl_surface,
    toplevel: *c.xdg_toplevel,
    interfaces: Interfaces,

    // input stuff
    keyboard: ?*c.wl_keyboard = null,
    pointer: ?*c.wl_pointer = null,

    // keyboard stuff
    xkb_context: *c.xkb_context,
    xkb_state: ?*c.xkb_state = null,
    compose_state: ?*c.xkb_compose_state = null,
    keymap: ?*c.xkb_keymap = null,
    modifiers: Core.KeyMods,
    modifier_indices: KeyModInd,
};

pub fn initWindow(
    core: *Core,
    window_id: mach.ObjectID,
) !void {
    core_ptr = core;
    var core_window = core.windows.getValue(window_id);
    libwaylandclient = try LibWaylandClient.load();
    libxkbcommon = try LibXkbCommon.load();

    core_window.native = .{
        .wayland = .{
            .interfaces = Interfaces{},
            .display = libwaylandclient.?.wl_display_connect(null) orelse return error.FailedToConnectToDisplay,
            .modifiers = .{
                .alt = false,
                .caps_lock = false,
                .control = false,
                .num_lock = false,
                .shift = false,
                .super = false,
            },
            .modifier_indices = .{ // TODO: make sure these are always getting initialized, we don't want undefined behavior
                .control_index = undefined,
                .alt_index = undefined,
                .shift_index = undefined,
                .super_index = undefined,
                .caps_lock_index = undefined,
                .num_lock_index = undefined,
            },
            // These undefined values require the initialization of `.interfaces` which happens in the registry listener
            .surface_descriptor = undefined,
            .surface = undefined,
            .toplevel = undefined,
            .xkb_context = libxkbcommon.?.xkb_context_new(0) orelse return error.FailedToGetXkbContext,
        },
    };

    // Save so that the new `.native` value is accessible from the registry listener
    core.windows.setValue(window_id, core_window);
    var wl = &core_window.native.?.wayland;

    const registry = c.wl_display_get_registry(wl.display) orelse return error.FailedToGetDisplayRegistry;

    if (c.wl_registry_add_listener(registry, &registry_listener.listener, @ptrFromInt(window_id)) != 0) {
        return error.ListenerHasAlreadyBeenSet;
    }

    // TODO: Look at replacing these 2 calls to wl_display_roundtrip with wl_display::sync
    // Round trip to get all the registry objects
    _ = libwaylandclient.?.wl_display_roundtrip(wl.display);

    // Round trip to get all initial output events
    _ = libwaylandclient.?.wl_display_roundtrip(wl.display);

    // Update `core_window` since registry listener and seat listener changed values in it
    core_window = core.windows.getValue(window_id);
    wl = &core_window.native.?.wayland;

    if (wl.interfaces.zxdg_decoration_manager_v1 == null) {
        return error.NoServerSideDecorationSupport;
    }

    // Setup surface
    wl.surface = c.wl_compositor_create_surface(wl.interfaces.wl_compositor) orelse return error.UnableToCreateSurface;
    wl.surface_descriptor = .{ .display = wl.display, .surface = wl.surface };
    core_window.surface_descriptor = .{ .next_in_chain = .{
        .from_wayland_surface = &wl.surface_descriptor,
    } };

    // Setup opaque region
    {
        const region = c.wl_compositor_create_region(wl.interfaces.wl_compositor) orelse return error.CouldntCreateWaylandRegtion;

        c.wl_region_add(
            region,
            0,
            0,
            @intCast(core_window.width),
            @intCast(core_window.height),
        );
        c.wl_surface_set_opaque_region(wl.surface, region);
        c.wl_region_destroy(region);
    }

    const xdg_surface = c.xdg_wm_base_get_xdg_surface(wl.interfaces.xdg_wm_base, wl.surface) orelse return error.UnableToCreateXdgSurface;
    wl.toplevel = c.xdg_surface_get_toplevel(xdg_surface) orelse return error.UnableToGetXdgTopLevel;

    // Save so that xdg listeners can use the `wl.surface`
    core_ptr.windows.setValue(window_id, core_window);

    if (c.xdg_surface_add_listener(xdg_surface, &xdg_surface_listener.listener, @ptrFromInt(window_id)) != 0) {
        return error.ListenerHasAlreadyBeenSet;
    }

    if (c.xdg_toplevel_add_listener(wl.toplevel, &xdg_toplevel_listener.listener, @ptrFromInt(window_id)) != 0) {
        return error.ListenerHasAlreadyBeenSet;
    }

    // Wait for events to get pushed
    _ = libwaylandclient.?.wl_display_roundtrip(wl.display);

    core_window = core.windows.getValue(window_id);
    wl = &core_window.native.?.wayland;

    // Commit changes to surface
    c.wl_surface_commit(wl.surface);

    while (true) {
        const result = libwaylandclient.?.wl_display_dispatch(wl.display);

        core_window = core.windows.getValue(window_id);
        wl = &core_window.native.?.wayland;

        if (result != -1 and wl.configured) break;
    }

    c.xdg_toplevel_set_title(wl.toplevel, @ptrCast(core_window.title));

    const decoration = c.zxdg_decoration_manager_v1_get_toplevel_decoration(
        wl.interfaces.zxdg_decoration_manager_v1,
        wl.toplevel,
    ) orelse return error.UnableToGetToplevelDecoration;

    c.zxdg_toplevel_decoration_v1_set_mode(decoration, c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);

    // Commit changes to surface
    c.wl_surface_commit(wl.surface);

    _ = libwaylandclient.?.wl_display_roundtrip(wl.display);

    core.windows.setValue(window_id, core_window);
    try core.initWindow(window_id);
}

// pub fn deinit(
//     wl: *Wayland,
//     linux: *Linux,
// ) void {
//     linux.allocator.destroy(wl.surface_descriptor);
// }

pub fn tick(window_id: mach.ObjectID) !void {
    const wl = &core_ptr.windows.getValue(window_id).native.?.wayland;

    while (libwaylandclient.?.wl_display_flush(wl.display) == -1) {
        if (std.posix.errno(-1) == std.posix.E.AGAIN) {
            log.err("flush error", .{});
            return error.FlushError;
        }
        var pollfd = [_]std.posix.pollfd{
            std.posix.pollfd{
                .fd = libwaylandclient.?.wl_display_get_fd(wl.display),
                .events = std.posix.POLL.OUT,
                .revents = 0,
            },
        };
        while (try std.posix.poll(&pollfd, 1) == -1) {
            const errno = std.posix.errno(-1);
            if (errno == std.posix.E.INTR or errno == std.posix.E.AGAIN) {
                log.err("poll error", .{});
                return error.PollError;
            }
        }
    }

    _ = libwaylandclient.?.wl_display_roundtrip(wl.display);
}

pub fn setTitle(wl: *const Native, title: [:0]const u8) void {
    c.xdg_toplevel_set_title(wl.toplevel, title);
}

pub fn setDisplayMode(wl: *Wayland, display_mode: DisplayMode) void {
    _ = wl;
    _ = display_mode;
}

pub const LibXkbCommon = struct {
    handle: std.DynLib,

    xkb_context_new: *const @TypeOf(c.xkb_context_new),
    xkb_keymap_new_from_string: *const @TypeOf(c.xkb_keymap_new_from_string),
    xkb_state_new: *const @TypeOf(c.xkb_state_new),
    xkb_keymap_unref: *const @TypeOf(c.xkb_keymap_unref),
    xkb_state_unref: *const @TypeOf(c.xkb_state_unref),
    xkb_compose_table_new_from_locale: *const @TypeOf(c.xkb_compose_table_new_from_locale),
    xkb_compose_state_new: *const @TypeOf(c.xkb_compose_state_new),
    xkb_compose_table_unref: *const @TypeOf(c.xkb_compose_table_unref),
    xkb_keymap_mod_get_index: *const @TypeOf(c.xkb_keymap_mod_get_index),
    xkb_state_update_mask: *const @TypeOf(c.xkb_state_update_mask),
    xkb_state_mod_index_is_active: *const @TypeOf(c.xkb_state_mod_index_is_active),
    xkb_state_key_get_syms: *const @TypeOf(c.xkb_state_key_get_syms),
    xkb_compose_state_feed: *const @TypeOf(c.xkb_compose_state_feed),
    xkb_compose_state_get_status: *const @TypeOf(c.xkb_compose_state_get_status),
    xkb_compose_state_get_one_sym: *const @TypeOf(c.xkb_compose_state_get_one_sym),
    xkb_keysym_to_utf32: *const @TypeOf(c.xkb_keysym_to_utf32),

    pub const lib_name = "libxkbcommon.so.0";

    pub fn load() !LibXkbCommon {
        var lib: LibXkbCommon = undefined;
        lib.handle = std.DynLib.open(lib_name) catch return error.LibraryNotFound;
        inline for (@typeInfo(LibXkbCommon).@"struct".fields[1..]) |field| {
            const name = std.fmt.comptimePrint("{s}\x00", .{field.name});
            const name_z: [:0]const u8 = @ptrCast(name[0 .. name.len - 1]);
            @field(lib, field.name) = lib.handle.lookup(field.type, name_z) orelse {
                log.err("Symbol lookup failed for {s}", .{name});
                return error.SymbolLookup;
            };
        }
        return lib;
    }
};

pub const LibWaylandClient = struct {
    handle: std.DynLib,

    wl_display_connect: *const @TypeOf(c.wl_display_connect),
    wl_display_roundtrip: *const @TypeOf(c.wl_display_roundtrip),
    wl_display_dispatch: *const @TypeOf(c.wl_display_dispatch),
    wl_display_dispatch_pending: *const @TypeOf(c.wl_display_dispatch_pending),
    wl_display_flush: *const @TypeOf(c.wl_display_flush),
    wl_display_get_fd: *const @TypeOf(c.wl_display_get_fd),
    wl_proxy_add_listener: *const @TypeOf(c.wl_proxy_add_listener),
    wl_proxy_get_version: *const @TypeOf(c.wl_proxy_get_version),
    wl_proxy_marshal_flags: *const @TypeOf(c.wl_proxy_marshal_flags),
    wl_proxy_set_tag: *const @TypeOf(c.wl_proxy_set_tag),
    wl_proxy_destroy: *const @TypeOf(c.wl_proxy_destroy),

    //Interfaces
    wl_compositor_interface: *@TypeOf(c.wl_compositor_interface),
    wl_subcompositor_interface: *@TypeOf(c.wl_subcompositor_interface),
    wl_shm_interface: *@TypeOf(c.wl_subcompositor_interface),
    wl_data_device_manager_interface: *@TypeOf(c.wl_data_device_manager_interface),

    wl_buffer_interface: *@TypeOf(c.wl_buffer_interface),
    wl_callback_interface: *@TypeOf(c.wl_callback_interface),
    wl_data_device_interface: *@TypeOf(c.wl_data_device_interface),
    wl_data_offer_interface: *@TypeOf(c.wl_data_offer_interface),
    wl_data_source_interface: *@TypeOf(c.wl_data_source_interface),
    wl_keyboard_interface: *@TypeOf(c.wl_keyboard_interface),
    wl_output_interface: *@TypeOf(c.wl_output_interface),
    wl_pointer_interface: *@TypeOf(c.wl_pointer_interface),
    wl_region_interface: *@TypeOf(c.wl_region_interface),
    wl_registry_interface: *@TypeOf(c.wl_registry_interface),
    wl_seat_interface: *@TypeOf(c.wl_seat_interface),
    wl_shell_surface_interface: *@TypeOf(c.wl_shell_surface_interface),
    wl_shm_pool_interface: *@TypeOf(c.wl_shm_pool_interface),
    wl_subsurface_interface: *@TypeOf(c.wl_subsurface_interface),
    wl_surface_interface: *@TypeOf(c.wl_surface_interface),
    wl_touch_interface: *@TypeOf(c.wl_touch_interface),

    pub const lib_name = "libwayland-client.so.0";

    pub fn load() !LibWaylandClient {
        var lib: LibWaylandClient = undefined;
        lib.handle = std.DynLib.open(lib_name) catch return error.LibraryNotFound;
        inline for (@typeInfo(LibWaylandClient).@"struct".fields[1..]) |field| {
            const name = std.fmt.comptimePrint("{s}\x00", .{field.name});
            const name_z: [:0]const u8 = @ptrCast(name[0 .. name.len - 1]);
            @field(lib, field.name) = lib.handle.lookup(field.type, name_z) orelse {
                log.err("Symbol lookup failed for {s}", .{name});
                return error.SymbolLookup;
            };
        }
        return lib;
    }
};

const Interfaces = struct {
    wl_compositor: ?*c.wl_compositor = null,
    wl_subcompositor: ?*c.wl_subcompositor = null,
    wl_shm: ?*c.wl_shm = null,
    wl_output: ?*c.wl_output = null,
    wl_seat: ?*c.wl_seat = null,
    wl_data_device_manager: ?*c.wl_data_device_manager = null,
    xdg_wm_base: ?*c.xdg_wm_base = null,
    zxdg_decoration_manager_v1: ?*c.zxdg_decoration_manager_v1 = null,
};

const KeyModInd = struct {
    control_index: c.xkb_mod_index_t,
    alt_index: c.xkb_mod_index_t,
    shift_index: c.xkb_mod_index_t,
    super_index: c.xkb_mod_index_t,
    caps_lock_index: c.xkb_mod_index_t,
    num_lock_index: c.xkb_mod_index_t,
};

const registry_listener = struct {
    fn registryHandleGlobal(window_id: mach.ObjectID, registry: ?*c.struct_wl_registry, name: u32, interface_ptr: [*:0]const u8, version: u32) callconv(.C) void {
        const interface = std.mem.span(interface_ptr);
        var core_window = core_ptr.windows.getValue(window_id);
        const wl = &core_window.native.?.wayland;

        if (std.mem.eql(u8, "wl_compositor", interface)) {
            wl.interfaces.wl_compositor = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                libwaylandclient.?.wl_compositor_interface,
                @min(3, version),
            ) orelse @panic("uh idk how to proceed"));
        } else if (std.mem.eql(u8, "wl_subcompositor", interface)) {
            // TODO: Remove this binding because we aren't using wl_shm
            wl.interfaces.wl_subcompositor = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                libwaylandclient.?.wl_subcompositor_interface,
                @min(3, version),
            ) orelse @panic("uh idk how to proceed"));
        } else if (std.mem.eql(u8, "wl_shm", interface)) {
            // TODO: Remove this binding because we aren't using wl_shm
            wl.interfaces.wl_shm = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                libwaylandclient.?.wl_shm_interface,
                @min(3, version),
            ) orelse @panic("uh idk how to proceed"));
        } else if (std.mem.eql(u8, "wl_output", interface)) {
            // TODO: Determine if this is being used. If it is, make a comment here
            wl.interfaces.wl_output = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                libwaylandclient.?.wl_output_interface,
                @min(3, version),
            ) orelse @panic("uh idk how to proceed"));
            // } else if (std.mem.eql(u8, "wl_data_device_manager", interface)) {
            //     wl.interfaces.wl_data_device_manager = @ptrCast(c.wl_registry_bind(
            //         registry,
            //         name,
            //         libwaylandclient.?.wl_data_device_manager_interface,
            //         @min(3, version),
            //     ) orelse @panic("uh idk how to proceed"));
        } else if (std.mem.eql(u8, "xdg_wm_base", interface)) {
            wl.interfaces.xdg_wm_base = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.xdg_wm_base_interface,
                @min(3, version),
            ) orelse @panic("uh idk how to proceed"));

            // TODO: handle return value
            _ = c.xdg_wm_base_add_listener(wl.interfaces.xdg_wm_base, &xdg_wm_base_listener.listener, @ptrFromInt(window_id));
        } else if (std.mem.eql(u8, "zxdg_decoration_manager_v1", interface)) {
            wl.interfaces.zxdg_decoration_manager_v1 = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.zxdg_decoration_manager_v1_interface,
                @min(3, version),
            ) orelse @panic("uh idk how to proceed"));
        } else if (std.mem.eql(u8, "wl_seat", interface)) {
            wl.interfaces.wl_seat = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                libwaylandclient.?.wl_seat_interface,
                @min(3, version),
            ) orelse @panic("uh idk how to proceed"));

            // TODO: handle return value
            _ = c.wl_seat_add_listener(wl.interfaces.wl_seat, &seat_listener.listener, @ptrFromInt(window_id));
        } else {
            // No changes made to `wl`, so exit function
            return;
        }
        core_ptr.windows.setValue(window_id, core_window);
    }

    fn registryHandleGlobalRemove(window_id: mach.ObjectID, registry: ?*c.struct_wl_registry, name: u32) callconv(.C) void {
        _ = window_id;
        _ = registry;
        _ = name;
    }

    const listener = c.wl_registry_listener{
        // ptrcast is for the [*:0] -> [*c] conversion, silly yes
        .global = @ptrCast(&registryHandleGlobal),
        // ptrcast is for the wl param, which is guarenteed to be our type (and if its not, it should be caught by safety checks)
        .global_remove = @ptrCast(&registryHandleGlobalRemove),
    };
};

const keyboard_listener = struct {
    fn keyboardHandleKeymap(window_id: mach.ObjectID, keyboard: ?*c.struct_wl_keyboard, format: u32, fd: i32, keymap_size: u32) callconv(.C) void {
        _ = keyboard;
        var core_window = core_ptr.windows.getValue(window_id);
        const wl = &core_window.native.?.wayland;

        if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
            @panic("TODO");
        }

        const map_str = std.posix.mmap(null, keymap_size, std.posix.PROT.READ, .{ .TYPE = .SHARED }, fd, 0) catch unreachable;

        const keymap = libxkbcommon.?.xkb_keymap_new_from_string(
            wl.xkb_context,
            @alignCast(map_str), //align cast happening here, im sure its fine? TODO: figure out if this okay
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            0,
        ).?;

        //Unmap the keymap
        std.posix.munmap(map_str);
        //Close the fd
        std.posix.close(fd);

        //Release reference to old state and create new state
        libxkbcommon.?.xkb_state_unref(wl.xkb_state);
        const state = libxkbcommon.?.xkb_state_new(keymap).?;

        //this chain hurts me. why must C be this way.
        const locale = std.posix.getenv("LC_ALL") orelse std.posix.getenv("LC_CTYPE") orelse std.posix.getenv("LANG") orelse "C";

        var compose_table = libxkbcommon.?.xkb_compose_table_new_from_locale(
            wl.xkb_context,
            locale,
            c.XKB_COMPOSE_COMPILE_NO_FLAGS,
        );

        //If creation failed, lets try the C locale
        if (compose_table == null)
            compose_table = libxkbcommon.?.xkb_compose_table_new_from_locale(
                wl.xkb_context,
                "C",
                c.XKB_COMPOSE_COMPILE_NO_FLAGS,
            ).?;

        defer libxkbcommon.?.xkb_compose_table_unref(compose_table);

        wl.keymap = keymap;
        wl.xkb_state = state;
        wl.compose_state = libxkbcommon.?.xkb_compose_state_new(compose_table, c.XKB_COMPOSE_STATE_NO_FLAGS).?;

        wl.modifier_indices.control_index = libxkbcommon.?.xkb_keymap_mod_get_index(keymap, "Control");
        wl.modifier_indices.alt_index = libxkbcommon.?.xkb_keymap_mod_get_index(keymap, "Mod1");
        wl.modifier_indices.shift_index = libxkbcommon.?.xkb_keymap_mod_get_index(keymap, "Shift");
        wl.modifier_indices.super_index = libxkbcommon.?.xkb_keymap_mod_get_index(keymap, "Mod4");
        wl.modifier_indices.caps_lock_index = libxkbcommon.?.xkb_keymap_mod_get_index(keymap, "Lock");
        wl.modifier_indices.num_lock_index = libxkbcommon.?.xkb_keymap_mod_get_index(keymap, "Mod2");

        core_ptr.windows.setValue(window_id, core_window);
    }

    fn keyboardHandleEnter(window_id: mach.ObjectID, keyboard: ?*c.struct_wl_keyboard, serial: u32, surface: ?*c.struct_wl_surface, keys: [*c]c.struct_wl_array) callconv(.C) void {
        _ = keyboard;
        _ = serial;
        _ = surface;
        _ = keys;

        core_ptr.pushEvent(.{ .focus_gained = .{ .window_id = window_id } });
    }

    fn keyboardHandleLeave(window_id: mach.ObjectID, keyboard: ?*c.struct_wl_keyboard, serial: u32, surface: ?*c.struct_wl_surface) callconv(.C) void {
        _ = keyboard;
        _ = serial;
        _ = surface;

        core_ptr.pushEvent(.{ .focus_lost = .{ .window_id = window_id } });
    }

    fn keyboardHandleKey(window_id: mach.ObjectID, keyboard: ?*c.struct_wl_keyboard, serial: u32, time: u32, scancode: u32, state: u32) callconv(.C) void {
        _ = keyboard;
        _ = serial;
        _ = time;
        const wl = &core_ptr.windows.getValue(window_id).native.?.wayland;

        const pressed = state == 1;

        const key_event = KeyEvent{ .key = toMachKey(scancode), .mods = wl.modifiers, .window_id = window_id };

        if (pressed) {
            core_ptr.pushEvent(.{ .key_press = key_event });

            var keysyms: ?[*]const c.xkb_keysym_t = undefined;
            //Get the keysym from the keycode (scancode + 8)
            if (libxkbcommon.?.xkb_state_key_get_syms(wl.xkb_state, scancode + 8, &keysyms) == 1) {
                //Compose the keysym
                const keysym: c.xkb_keysym_t = composeSymbol(wl, keysyms.?[0]);

                //Try to convert that keysym to a unicode codepoint
                const codepoint = libxkbcommon.?.xkb_keysym_to_utf32(keysym);
                if (codepoint != 0) {
                    core_ptr.pushEvent(.{ .char_input = .{ .codepoint = @truncate(codepoint), .window_id = window_id } });
                }
            }
        } else {
            core_ptr.pushEvent(.{ .key_release = key_event });
        }
    }

    fn keyboardHandleModifiers(window_id: mach.ObjectID, keyboard: ?*c.struct_wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.C) void {
        _ = keyboard;
        _ = serial;
        var core_window = core_ptr.windows.getValue(window_id);
        const wl = &core_window.native.?.wayland;

        if (wl.keymap == null)
            return;

        // TODO: handle this return value
        _ = libxkbcommon.?.xkb_state_update_mask(
            wl.xkb_state.?,
            mods_depressed,
            mods_latched,
            mods_locked,
            0,
            0,
            group,
        );

        //Iterate over all the modifiers
        inline for (.{
            .{ wl.modifier_indices.alt_index, "alt" },
            .{ wl.modifier_indices.shift_index, "shift" },
            .{ wl.modifier_indices.super_index, "super" },
            .{ wl.modifier_indices.control_index, "control" },
            .{ wl.modifier_indices.num_lock_index, "num_lock" },
            .{ wl.modifier_indices.caps_lock_index, "caps_lock" },
        }) |key| {
            @field(wl.modifiers, key[1]) = libxkbcommon.?.xkb_state_mod_index_is_active(
                wl.xkb_state,
                key[0],
                c.XKB_STATE_MODS_EFFECTIVE,
            ) == 1;
        }

        core_ptr.windows.setValue(window_id, core_window);
    }

    fn keyboardHandleRepeatInfo(window_id: mach.ObjectID, keyboard: ?*c.struct_wl_keyboard, rate: i32, delay: i32) callconv(.C) void {
        _ = window_id;
        _ = keyboard;
        _ = rate;
        _ = delay;
    }

    const listener = c.wl_keyboard_listener{
        .keymap = @ptrCast(&keyboardHandleKeymap),
        .enter = @ptrCast(&keyboardHandleEnter),
        .leave = @ptrCast(&keyboardHandleLeave),
        .key = @ptrCast(&keyboardHandleKey),
        .modifiers = @ptrCast(&keyboardHandleModifiers),
        .repeat_info = @ptrCast(&keyboardHandleRepeatInfo),
    };
};

const pointer_listener = struct {
    fn handlePointerAxis(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.C) void {
        _ = window_id;
        _ = pointer;
        _ = time;
        _ = axis;
        _ = value;
    }

    fn handlePointerFrame(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer) callconv(.C) void {
        _ = window_id;
        _ = pointer;
    }

    fn handlePointerAxisSource(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, axis_source: u32) callconv(.C) void {
        _ = window_id;
        _ = pointer;
        _ = axis_source;
    }

    fn handlePointerAxisStop(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, time: u32, axis: u32) callconv(.C) void {
        _ = window_id;
        _ = pointer;
        _ = time;
        _ = axis;
    }

    fn handlePointerAxisDiscrete(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, axis: u32, discrete: i32) callconv(.C) void {
        _ = window_id;
        _ = pointer;
        _ = axis;
        _ = discrete;
    }

    fn handlePointerAxisValue120(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, axis: u32, value_120: i32) callconv(.C) void {
        _ = window_id;
        _ = pointer;
        _ = axis;
        _ = value_120;
    }

    fn handlePointerAxisRelativeDirection(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, axis: u32, direction: u32) callconv(.C) void {
        _ = window_id;
        _ = pointer;
        _ = axis;
        _ = direction;
    }

    fn handlePointerEnter(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface, fixed_x: c.wl_fixed_t, fixed_y: c.wl_fixed_t) callconv(.C) void {
        _ = fixed_x;
        _ = fixed_y;
        _ = window_id;
        _ = pointer;
        _ = serial;
        _ = surface;
    }

    fn handlePointerLeave(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface) callconv(.C) void {
        _ = window_id;
        _ = pointer;
        _ = serial;
        _ = surface;
    }

    fn handlePointerMotion(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, serial: u32, fixed_x: c.wl_fixed_t, fixed_y: c.wl_fixed_t) callconv(.C) void {
        _ = pointer;
        _ = serial;

        const x = c.wl_fixed_to_double(fixed_x);
        const y = c.wl_fixed_to_double(fixed_y);

        core_ptr.pushEvent(.{ .mouse_motion = .{ .pos = .{ .x = x, .y = y }, .window_id = window_id } });
    }

    fn handlePointerButton(window_id: mach.ObjectID, pointer: ?*c.struct_wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.C) void {
        _ = pointer;
        _ = serial;
        _ = time;
        const wl = &core_ptr.windows.getValue(window_id).native.?.wayland;

        const mouse_button: Core.MouseButton = @enumFromInt(button - c.BTN_LEFT);
        const pressed = state == c.WL_POINTER_BUTTON_STATE_PRESSED;
        const x = core_ptr.input_state.mouse_position.x;
        const y = core_ptr.input_state.mouse_position.y;

        if (pressed) {
            core_ptr.pushEvent(Core.Event{ .mouse_press = .{
                .button = mouse_button,
                .mods = wl.modifiers,
                .pos = .{ .x = x, .y = y },
                .window_id = window_id,
            } });
        } else {
            core_ptr.pushEvent(Core.Event{ .mouse_release = .{
                .button = mouse_button,
                .mods = wl.modifiers,
                .pos = .{ .x = x, .y = y },
                .window_id = window_id,
            } });
        }
    }

    const listener = c.wl_pointer_listener{
        .axis = @ptrCast(&handlePointerAxis),
        .axis_discrete = @ptrCast(&handlePointerAxisDiscrete),
        .axis_relative_direction = @ptrCast(&handlePointerAxisRelativeDirection),
        .axis_source = @ptrCast(&handlePointerAxisSource),
        .axis_stop = @ptrCast(&handlePointerAxisStop),
        .axis_value120 = @ptrCast(&handlePointerAxisValue120),
        .button = @ptrCast(&handlePointerButton),
        .enter = @ptrCast(&handlePointerEnter),
        .frame = @ptrCast(&handlePointerFrame),
        .leave = @ptrCast(&handlePointerLeave),
        .motion = @ptrCast(&handlePointerMotion),
    };
};

const seat_listener = struct {
    fn seatHandleName(window_id: mach.ObjectID, seat: ?*c.struct_wl_seat, name_ptr: [*:0]const u8) callconv(.C) void {
        _ = window_id;
        _ = seat;
        _ = name_ptr;
    }

    fn seatHandleCapabilities(window_id: mach.ObjectID, seat: ?*c.struct_wl_seat, caps: c.wl_seat_capability) callconv(.C) void {
        var core_window = core_ptr.windows.getValue(window_id);
        const wl = &core_window.native.?.wayland;
        var changed = false;

        if ((caps & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0) {
            changed = true;
            wl.keyboard = c.wl_seat_get_keyboard(seat);

            // TODO: handle return value
            _ = c.wl_keyboard_add_listener(wl.keyboard, &keyboard_listener.listener, @ptrFromInt(window_id));
        }

        if ((caps & c.WL_SEAT_CAPABILITY_TOUCH) != 0) {
            // TODO
        }

        if ((caps & c.WL_SEAT_CAPABILITY_POINTER) != 0) {
            changed = true;
            wl.pointer = c.wl_seat_get_pointer(seat);

            // TODO: handle return value
            _ = c.wl_pointer_add_listener(wl.pointer, &pointer_listener.listener, @ptrFromInt(window_id));
        }

        // Delete keyboard if its no longer in the seat
        if (wl.keyboard) |keyboard| {
            if ((caps & c.WL_SEAT_CAPABILITY_KEYBOARD) == 0) {
                changed = true;
                c.wl_keyboard_destroy(keyboard);
                wl.keyboard = null;
            }
        }

        if (wl.pointer) |pointer| {
            if ((caps & c.WL_SEAT_CAPABILITY_POINTER) == 0) {
                changed = true;
                c.wl_pointer_destroy(pointer);
                wl.pointer = null;
            }
        }

        if (changed) {
            core_ptr.windows.setValue(window_id, core_window);
        }
    }

    const listener = c.wl_seat_listener{
        .capabilities = @ptrCast(&seatHandleCapabilities),
        .name = @ptrCast(&seatHandleName), //ptrCast for the `[*:0]const u8`
    };
};

const xdg_wm_base_listener = struct {
    fn wmBaseHandlePing(window_id: mach.ObjectID, wm_base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.C) void {
        _ = window_id;
        c.xdg_wm_base_pong(wm_base, serial);
    }

    const listener = c.xdg_wm_base_listener{ .ping = @ptrCast(&wmBaseHandlePing) };
};

const xdg_surface_listener = struct {
    fn xdgSurfaceHandleConfigure(window_id: mach.ObjectID, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.C) void {
        c.xdg_surface_ack_configure(xdg_surface, serial);
        var core_window = core_ptr.windows.getValue(window_id);
        const wl = &core_window.native.?.wayland;

        if (wl.configured) {
            c.wl_surface_commit(wl.surface);
        } else {
            wl.configured = true;
            core_ptr.windows.setValue(window_id, core_window);
            core_window = core_ptr.windows.getValue(window_id);
        }

        setContentAreaOpaque(wl, Core.Size{ .width = core_window.width, .height = core_window.height });
    }

    const listener = c.xdg_surface_listener{ .configure = @ptrCast(&xdgSurfaceHandleConfigure) };
};

const xdg_toplevel_listener = struct {
    fn xdgToplevelHandleClose(window_id: mach.ObjectID, toplevel: ?*c.struct_xdg_toplevel) callconv(.C) void {
        // TODO: implement this
        _ = window_id;
        _ = toplevel;
    }

    fn xdgToplevelHandleConfigure(window_id: mach.ObjectID, toplevel: ?*c.struct_xdg_toplevel, width: i32, height: i32, states: [*c]c.struct_wl_array) callconv(.C) void {
        var core_window = core_ptr.windows.getValue(window_id);
        _ = toplevel;
        _ = states;

        if (width > 0 and height > 0) {
            core_window.width = @intCast(width);
            core_window.height = @intCast(height);
            core_ptr.windows.setValue(window_id, core_window);
        }
    }

    const listener = c.xdg_toplevel_listener{
        .configure = @ptrCast(&xdgToplevelHandleConfigure),
        .close = @ptrCast(&xdgToplevelHandleClose),
    };
};

fn composeSymbol(wl: *const Native, sym: c.xkb_keysym_t) c.xkb_keysym_t {
    if (sym == c.XKB_KEY_NoSymbol or wl.compose_state == null)
        return sym;

    if (libxkbcommon.?.xkb_compose_state_feed(wl.compose_state, sym) != c.XKB_COMPOSE_FEED_ACCEPTED)
        return sym;

    return switch (libxkbcommon.?.xkb_compose_state_get_status(wl.compose_state)) {
        c.XKB_COMPOSE_COMPOSED => libxkbcommon.?.xkb_compose_state_get_one_sym(wl.compose_state),
        c.XKB_COMPOSE_COMPOSING, c.XKB_COMPOSE_CANCELLED => c.XKB_KEY_NoSymbol,
        else => sym,
    };
}

fn toMachKey(key: u32) Core.Key {
    return switch (key) {
        c.KEY_GRAVE => .grave,
        c.KEY_1 => .one,
        c.KEY_2 => .two,
        c.KEY_3 => .three,
        c.KEY_4 => .four,
        c.KEY_5 => .five,
        c.KEY_6 => .six,
        c.KEY_7 => .seven,
        c.KEY_8 => .eight,
        c.KEY_9 => .nine,
        c.KEY_0 => .zero,
        c.KEY_SPACE => .space,
        c.KEY_MINUS => .minus,
        c.KEY_EQUAL => .equal,
        c.KEY_Q => .q,
        c.KEY_W => .w,
        c.KEY_E => .e,
        c.KEY_R => .r,
        c.KEY_T => .t,
        c.KEY_Y => .y,
        c.KEY_U => .u,
        c.KEY_I => .i,
        c.KEY_O => .o,
        c.KEY_P => .p,
        c.KEY_LEFTBRACE => .left_bracket,
        c.KEY_RIGHTBRACE => .right_bracket,
        c.KEY_A => .a,
        c.KEY_S => .s,
        c.KEY_D => .d,
        c.KEY_F => .f,
        c.KEY_G => .g,
        c.KEY_H => .h,
        c.KEY_J => .j,
        c.KEY_K => .k,
        c.KEY_L => .l,
        c.KEY_SEMICOLON => .semicolon,
        c.KEY_APOSTROPHE => .apostrophe,
        c.KEY_Z => .z,
        c.KEY_X => .x,
        c.KEY_C => .c,
        c.KEY_V => .v,
        c.KEY_B => .b,
        c.KEY_N => .n,
        c.KEY_M => .m,
        c.KEY_COMMA => .comma,
        c.KEY_DOT => .period,
        c.KEY_SLASH => .slash,
        c.KEY_BACKSLASH => .backslash,
        c.KEY_ESC => .escape,
        c.KEY_TAB => .tab,
        c.KEY_LEFTSHIFT => .left_shift,
        c.KEY_RIGHTSHIFT => .right_shift,
        c.KEY_LEFTCTRL => .left_control,
        c.KEY_RIGHTCTRL => .right_control,
        c.KEY_LEFTALT => .left_alt,
        c.KEY_RIGHTALT => .right_alt,
        c.KEY_LEFTMETA => .left_super,
        c.KEY_RIGHTMETA => .right_super,
        c.KEY_NUMLOCK => .num_lock,
        c.KEY_CAPSLOCK => .caps_lock,
        c.KEY_PRINT => .print,
        c.KEY_SCROLLLOCK => .scroll_lock,
        c.KEY_PAUSE => .pause,
        c.KEY_DELETE => .delete,
        c.KEY_BACKSPACE => .backspace,
        c.KEY_ENTER => .enter,
        c.KEY_HOME => .home,
        c.KEY_END => .end,
        c.KEY_PAGEUP => .page_up,
        c.KEY_PAGEDOWN => .page_down,
        c.KEY_INSERT => .insert,
        c.KEY_LEFT => .left,
        c.KEY_RIGHT => .right,
        c.KEY_DOWN => .down,
        c.KEY_UP => .up,
        c.KEY_F1 => .f1,
        c.KEY_F2 => .f2,
        c.KEY_F3 => .f3,
        c.KEY_F4 => .f4,
        c.KEY_F5 => .f5,
        c.KEY_F6 => .f6,
        c.KEY_F7 => .f7,
        c.KEY_F8 => .f8,
        c.KEY_F9 => .f9,
        c.KEY_F10 => .f10,
        c.KEY_F11 => .f11,
        c.KEY_F12 => .f12,
        c.KEY_F13 => .f13,
        c.KEY_F14 => .f14,
        c.KEY_F15 => .f15,
        c.KEY_F16 => .f16,
        c.KEY_F17 => .f17,
        c.KEY_F18 => .f18,
        c.KEY_F19 => .f19,
        c.KEY_F20 => .f20,
        c.KEY_F21 => .f21,
        c.KEY_F22 => .f22,
        c.KEY_F23 => .f23,
        c.KEY_F24 => .f24,
        c.KEY_KPSLASH => .kp_divide,
        c.KEY_KPASTERISK => .kp_multiply,
        c.KEY_KPMINUS => .kp_subtract,
        c.KEY_KPPLUS => .kp_add,
        c.KEY_KP0 => .kp_0,
        c.KEY_KP1 => .kp_1,
        c.KEY_KP2 => .kp_2,
        c.KEY_KP3 => .kp_3,
        c.KEY_KP4 => .kp_4,
        c.KEY_KP5 => .kp_5,
        c.KEY_KP6 => .kp_6,
        c.KEY_KP7 => .kp_7,
        c.KEY_KP8 => .kp_8,
        c.KEY_KP9 => .kp_9,
        c.KEY_KPDOT => .kp_decimal,
        c.KEY_KPEQUAL => .kp_equal,
        c.KEY_KPENTER => .kp_enter,
        else => .unknown,
    };
}

fn setContentAreaOpaque(wl: *const Native, new_size: Core.Size) void {
    const region = c.wl_compositor_create_region(wl.interfaces.wl_compositor) orelse return;

    c.wl_region_add(region, 0, 0, @intCast(new_size.width), @intCast(new_size.height));
    c.wl_surface_set_opaque_region(wl.surface, region);
    c.wl_region_destroy(region);

    // FIX: What is the Mach Object System way of doing this?
    // core_ptr.swap_chain_update.set();
}
