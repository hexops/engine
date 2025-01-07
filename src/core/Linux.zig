const std = @import("std");
const mach = @import("../main.zig");
const Core = @import("../Core.zig");
const X11 = @import("linux/X11.zig");
const Wayland = @import("linux/Wayland.zig");
const gpu = mach.gpu;
const InitOptions = Core.InitOptions;
const Event = Core.Event;
const KeyEvent = Core.KeyEvent;
const MouseButtonEvent = Core.MouseButtonEvent;
const MouseButton = Core.MouseButton;
const Size = Core.Size;
const DisplayMode = Core.DisplayMode;
const CursorShape = Core.CursorShape;
const VSyncMode = Core.VSyncMode;
const CursorMode = Core.CursorMode;
const Position = Core.Position;
const Key = Core.Key;
const KeyMods = Core.KeyMods;

const log = std.log.scoped(.mach);
const gamemode_log = std.log.scoped(.gamemode);

const BackendEnum = enum {
    x11,
    wayland,
};

const Backend = union(BackendEnum) {
    x11: X11,
    wayland: Wayland,
};

pub const Native = union(BackendEnum) {
    x11: X11.Native,
    wayland: Wayland.Native,
};

pub const Linux = @This();

allocator: std.mem.Allocator,
title: [:0]const u8,

display_mode: DisplayMode,
vsync_mode: VSyncMode,
cursor_mode: CursorMode,
cursor_shape: CursorShape,
border: bool,
headless: bool,
refresh_rate: u32,
size: Size,
surface_descriptor: gpu.Surface.Descriptor,
gamemode: ?bool = null,
backend: Backend,

// these arrays are used as info messages to the user that some features are missing
// please keep these up to date until we can remove them
const MISSING_FEATURES_X11 = [_][]const u8{ "Resizing window", "Changing display mode", "VSync", "Setting window border/cursor" };
const MISSING_FEATURES_WAYLAND = [_][]const u8{ "Resizing window", "Changing display mode", "VSync", "Setting window border/cursor" };

pub fn tick(core: *Core) !void {
    var windows = core.windows.slice();
    while (windows.next()) |window_id| {
        const native_opt: ?Native = core.windows.get(window_id, .native);
        if (native_opt) |native| {
            check_for_mach_updates(core, window_id);
            // check for display server events
            switch (native) {
                .x11 => try X11.tick(window_id),
                .wayland => try Wayland.tick(window_id),
            }
        } else {
            try initWindow(core, window_id);
        }
    }
}

pub fn initWindow(
    core: *Core,
    window_id: mach.ObjectID,
) !void {
    const desired_backend: BackendEnum = blk: {
        const backend = std.process.getEnvVarOwned(
            core.allocator,
            "MACH_BACKEND",
        ) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                // default backend
                break :blk .wayland;
            },
            else => return err,
        };
        defer core.allocator.free(backend);

        if (std.ascii.eqlIgnoreCase(backend, "x11")) break :blk .x11;
        if (std.ascii.eqlIgnoreCase(backend, "wayland")) break :blk .wayland;
        std.debug.panic("mach: unknown MACH_BACKEND: {s}", .{backend});
    };

    // Try to initialize the desired backend, falling back to the other if that one is not supported
    switch (desired_backend) {
        .x11 => {
            X11.initWindow(core, window_id) catch |err| {
                const err_msg = switch (err) {
                    error.LibraryNotFound => "Missing X11 library",
                    error.FailedToConnectToDisplay => "Failed to connect to X11 display",
                    else => "An unknown error occured while trying to connect to X11",
                };
                log.err("{s}\n\nFalling back to Wayland\n", .{err_msg});
                Wayland.initWindow(core, window_id) catch |e| {
                    log.err("Failed to connect to fallback display server, Wayland.\n", .{});
                    var libs = std.ArrayList(u8).init(core.allocator);
                    defer libs.deinit();
                    if (X11.libx11 == null) {
                        try libs.appendSlice("\t* " ++ X11.LibX11.lib_name ++ "\n");
                    }
                    if (X11.libxkbcommon == null) {
                        try libs.appendSlice("\t* " ++ X11.LibXkbCommon.lib_name ++ "\n");
                    }
                    if (X11.libgl == null) {
                        try libs.appendSlice("\t* " ++ X11.LibGL.lib_name ++ "\n");
                    }
                    log.err("The following X11 libraries were not available:\n{s}", .{libs.items});
                    return e;
                };
            };
        },
        .wayland => {
            Wayland.initWindow(core, window_id) catch |err| {
                const err_msg = switch (err) {
                    error.NoServerSideDecorationSupport => "Server Side Decorations aren't supported",
                    error.LibraryNotFound => "Missing Wayland library",
                    error.FailedToConnectToDisplay => "Failed to connect to Wayland display",
                    else => "An unknown error occured while trying to connect to Wayland",
                };
                log.err("{s}\n\nFalling back to X11\n", .{err_msg});
                X11.initWindow(core, window_id) catch |e| {
                    log.err("Failed to connect to fallback display server, X11.\n", .{});
                    var libs = std.ArrayList(u8).init(core.allocator);
                    defer libs.deinit();
                    if (Wayland.libwaylandclient == null) {
                        try libs.appendSlice("\t* " ++ Wayland.LibWaylandClient.lib_name ++ "\n");
                    }
                    if (Wayland.libxkbcommon == null) {
                        try libs.appendSlice("\t* " ++ Wayland.LibXkbCommon.lib_name ++ "\n");
                    }
                    log.err("The following Wayland libraries were not available:\n{s}", .{libs.items});
                    return e;
                };
            };
        },
    }

    // warn about incomplete features
    // TODO: remove this when linux is not missing major features
    try warnAboutIncompleteFeatures(desired_backend, &MISSING_FEATURES_X11, &MISSING_FEATURES_WAYLAND, core.allocator);
}

// pub fn deinit(linux: *Linux) void {
//     if (linux.gamemode != null and linux.gamemode.?) deinitLinuxGamemode();
//
//     linux.allocator.free(linux.title);
//
//     switch (linux.backend) {
//         .wayland => linux.backend.wayland.deinit(linux),
//         .x11 => linux.backend.x11.deinit(linux),
//     }
// }

pub fn update(linux: *Linux) !void {
    switch (linux.backend) {
        .wayland => try linux.backend.wayland.update(linux),
        .x11 => try linux.backend.x11.update(linux),
    }
}

fn setTitle(native: *const Native, title: [:0]const u8) void {
    switch (native.*) {
        .wayland => |wl| Wayland.setTitle(&wl, title),
        .x11 => |x| X11.setTitle(&x, title),
    }
}

pub fn setDisplayMode(linux: *Linux, display_mode: DisplayMode) void {
    // const old_display_mode = linux.display_mode;
    linux.display_mode = display_mode;
    switch (linux.backend) {
        .wayland => linux.backend.wayland.setDisplayMode(display_mode),
        .x11 => linux.backend.x11.setDisplayMode(linux, display_mode),
    }
}

pub fn setBorder(_: *Linux, _: bool) void {
    return;
}

pub fn setHeadless(_: *Linux, _: bool) void {
    return;
}

pub fn setVSync(_: *Linux, _: VSyncMode) void {
    return;
}

pub fn setSize(_: *Linux, _: Size) void {
    return;
}

pub fn setCursorMode(_: *Linux, _: CursorMode) void {
    return;
}

pub fn setCursorShape(_: *Linux, _: CursorShape) void {
    return;
}

/// Checks for updates in mach object fields. Does nothing if window is not initialized.
fn check_for_mach_updates(core: *Core, window_id: mach.ObjectID) void {
    const core_window = core.windows.getValue(window_id);
    const native = &core_window.native;
    if (native.*) |n| {
        if (core.windows.updated(window_id, .title)) {
            setTitle(&n, core_window.title);
        }
    }
}

/// Check if gamemode should be activated
pub fn wantGamemode(allocator: std.mem.Allocator) error{ OutOfMemory, InvalidWtf8 }!bool {
    const use_gamemode = std.process.getEnvVarOwned(
        allocator,
        "MACH_USE_GAMEMODE",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return true,
        else => |e| return e,
    };
    defer allocator.free(use_gamemode);

    return !(std.ascii.eqlIgnoreCase(use_gamemode, "off") or std.ascii.eqlIgnoreCase(use_gamemode, "false"));
}

pub fn initLinuxGamemode() bool {
    mach.gamemode.start();
    if (!mach.gamemode.isActive()) return false;
    gamemode_log.info("gamemode: activated\n", .{});
    return true;
}

pub fn deinitLinuxGamemode() void {
    mach.gamemode.stop();
    gamemode_log.info("gamemode: deactivated\n", .{});
}

/// Used to inform users that some features are not present. Remove when features are complete.
fn warnAboutIncompleteFeatures(backend: BackendEnum, missing_features_x11: []const []const u8, missing_features_wayland: []const []const u8, alloc: std.mem.Allocator) !void {
    const features_incomplete_message =
        \\You are using the {s} backend, which is currently experimental as we continue to rewrite Mach in Zig instead of using C libraries like GLFW/etc. The following features are expected to not work:
        \\
        \\{s}
        \\
        \\Contributions welcome!
        \\
    ;
    const bullet_points = switch (backend) {
        .x11 => try generateFeatureBulletPoints(missing_features_x11, alloc),
        .wayland => try generateFeatureBulletPoints(missing_features_wayland, alloc),
    };
    defer bullet_points.deinit();
    log.warn(features_incomplete_message, .{ @tagName(backend), bullet_points.items });
}

/// Turn an array of strings into a single, bullet-pointed string, like this:
/// * Item one
/// * Item two
///
/// Returned value will need to be deinitialized.
fn generateFeatureBulletPoints(features: []const []const u8, alloc: std.mem.Allocator) !std.ArrayList(u8) {
    var message = std.ArrayList(u8).init(alloc);
    for (features, 0..) |str, i| {
        try message.appendSlice("* ");
        try message.appendSlice(str);
        if (i < features.len - 1) {
            try message.appendSlice("\n");
        }
    }
    return message;
}
