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

pub const Linux = @This();

allocator: std.mem.Allocator,

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
const MISSING_FEATURES_X11 = [_][]const u8{ "Resizing window", "Changing display mode", "VSync", "Setting window border/title/cursor" };
const MISSING_FEATURES_WAYLAND = [_][]const u8{ "Changing display mode", "VSync", "Setting window border/title/cursor" };

pub fn init(
    linux: *Linux,
    core: *Core.Mod,
    options: InitOptions,
) !void {
    linux.allocator = options.allocator;

    if (!options.is_app and try wantGamemode(linux.allocator)) linux.gamemode = initLinuxGamemode();
    linux.headless = options.headless;
    linux.refresh_rate = 60; // TODO: set to something meaningful
    linux.vsync_mode = .triple;
    linux.size = options.size;
    if (!options.headless) {
        // TODO: this function does nothing right now
        setDisplayMode(linux, options.display_mode);
    }

    const desired_backend: BackendEnum = blk: {
        const backend = std.process.getEnvVarOwned(
            linux.allocator,
            "MACH_BACKEND",
        ) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                break :blk .wayland;
            },
            else => return err,
        };
        defer linux.allocator.free(backend);

        if (std.ascii.eqlIgnoreCase(backend, "x11")) break :blk .x11;
        if (std.ascii.eqlIgnoreCase(backend, "wayland")) break :blk .wayland;
        std.debug.panic("mach: unknown MACH_BACKEND: {s}", .{backend});
    };

    // Try to initialize the desired backend, falling back to the other if that one is not supported
    switch (desired_backend) {
        .x11 => {
            X11.init(linux, core, options) catch |err| {
                const err_msg = switch (err) {
                    error.LibraryNotFound => "Missing X11 library",
                    error.FailedToConnectToDisplay => "Failed to connect to X11 display",
                    else => "An unknown error occured while trying to connect to X11",
                };
                log.err("{s}\nFalling back to Wayland\n", .{err_msg});
                try Wayland.init(linux, core, options);
            };
        },
        .wayland => {
            Wayland.init(linux, core, options) catch |err| {
                const err_msg = switch (err) {
                    error.LibraryNotFound => "Missing Wayland library",
                    error.FailedToConnectToDisplay => "Failed to connect to Wayland display",
                    else => "An unknown error occured while trying to connect to Wayland",
                };
                log.err("{s}\nFalling back to X11\n", .{err_msg});
                try X11.init(linux, core, options);
            };
        },
    }

    switch (linux.backend) {
        .wayland => |be| {
            linux.surface_descriptor = .{ .next_in_chain = .{ .from_wayland_surface = be.surface_descriptor } };
        },
        .x11 => |be| {
            linux.surface_descriptor = .{ .next_in_chain = .{ .from_xlib_window = be.surface_descriptor } };
        },
    }

    // warn about incomplete features
    // TODO: remove this when linux is not missing major features
    try warnAboutIncompleteFeatures(linux.backend, &MISSING_FEATURES_X11, &MISSING_FEATURES_WAYLAND, options.allocator);

    return;
}

pub fn deinit(linux: *Linux) void {
    if (linux.gamemode != null and linux.gamemode.?) deinitLinuxGamemode();
    switch (linux.backend) {
        .wayland => linux.backend.wayland.deinit(linux),
        .x11 => linux.backend.x11.deinit(linux),
    }

    return;
}

pub fn update(linux: *Linux) !void {
    switch (linux.backend) {
        .wayland => try linux.backend.wayland.update(),
        .x11 => try linux.backend.x11.update(),
    }
    return;
}

pub fn setTitle(_: *Linux, _: [:0]const u8) void {
    return;
}

pub fn setDisplayMode(_: *Linux, _: DisplayMode) void {
    return;
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
        \\WARNING: You are using the {s} backend, which is currently experimental as we continue to rewrite Mach in Zig instead of using C libraries like GLFW/etc. The following features are expected to not work:
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
    log.info(features_incomplete_message, .{ @tagName(backend), bullet_points.items });
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
