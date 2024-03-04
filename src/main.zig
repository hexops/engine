// Core re-exports
pub const core = @import("mach-core");
pub const Timer = core.Timer;

// Mach packages
pub const gpu = core.gpu;
pub const sysjs = @import("mach-sysjs");
pub const sysaudio = @import("mach-sysaudio");

// Mach standard library
pub const ecs = @import("ecs/main.zig");
pub const gamemode = @import("gamemode.zig");
pub const gfx = @import("gfx/main.zig");
pub const math = @import("math/main.zig");
pub const testing = @import("testing.zig");

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
    _ = gfx;
    _ = math;
    _ = testing;
    std.testing.refAllDeclsRecursive(ecs);
    std.testing.refAllDeclsRecursive(gamemode);
    std.testing.refAllDeclsRecursive(math);
}
