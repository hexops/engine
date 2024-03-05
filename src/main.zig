const build_options = @import("build-options");
const builtin = @import("builtin");

// Core
pub const core = if (build_options.want_core) @import("core/main.zig") else struct {};
pub const Timer = if (build_options.want_core) core.Timer else struct {};
pub const gpu = if (build_options.want_core) core.gpu else struct {};
pub const sysjs = if (build_options.want_core) @import("mach-sysjs") else struct {};

// Mach standard library
pub const ecs = @import("ecs/main.zig");
// gamemode requires libc on linux
pub const gamemode = if (builtin.os.tag != .linux or builtin.link_libc) @import("gamemode.zig");
pub const gfx = if (build_options.want_mach) @import("gfx/main.zig") else struct {};
pub const math = @import("math/main.zig");
pub const testing = @import("testing.zig");

pub const sysaudio = if (build_options.want_sysaudio) @import("sysaudio/main.zig") else struct {};
pub const sysgpu = if (build_options.want_sysgpu) @import("sysgpu/main.zig") else struct {};

// Engine exports
pub const App = @import("engine.zig").App;
pub const Engine = @import("engine.zig").Engine;
pub const World = @import("engine.zig").World;
pub const Mod = World.Mod;

test {
    const std = @import("std");
    // TODO: refactor code so we can use this here:
    // std.testing.refAllDeclsRecursive(@This());
    _ = core;
    _ = gpu;
    _ = sysaudio;
    _ = sysgpu;
    _ = gfx;
    _ = math;
    _ = testing;
    std.testing.refAllDeclsRecursive(ecs);
    std.testing.refAllDeclsRecursive(gamemode);
    std.testing.refAllDeclsRecursive(math);
}
