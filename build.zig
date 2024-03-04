const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("mach_glfw");
const sysaudio = @import("mach_sysaudio");
const core = @import("mach_core");

var _module: ?*std.Build.Module = null;

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const mach_core_dep = b.dependency("mach_core", .{
        .target = target,
        .optimize = optimize,
    });
    const mach_sysaudio_dep = b.dependency("mach_sysaudio", .{
        .target = target,
        .optimize = optimize,
    });
    const mach_basisu_dep = b.dependency("mach_basisu", .{
        .target = target,
        .optimize = optimize,
    });
    const mach_freetype_dep = b.dependency("mach_freetype", .{
        .target = target,
        .optimize = optimize,
    });
    const mach_sysjs_dep = b.dependency("mach_sysjs", .{
        .target = target,
        .optimize = optimize,
    });
    const font_assets_dep = b.dependency("font_assets", .{});

    const module = b.addModule("mach", .{
        .root_source_file = .{ .path = sdkPath("/src/main.zig") },
        .imports = &.{
            .{ .name = "mach-core", .module = mach_core_dep.module("mach-core") },
            .{ .name = "mach-sysaudio", .module = mach_sysaudio_dep.module("mach-sysaudio") },
            .{ .name = "mach-basisu", .module = mach_basisu_dep.module("mach-basisu") },
            .{ .name = "mach-freetype", .module = mach_freetype_dep.module("mach-freetype") },
            .{ .name = "mach-harfbuzz", .module = mach_freetype_dep.module("mach-harfbuzz") },
            .{ .name = "mach-sysjs", .module = mach_sysjs_dep.module("mach-sysjs") },
            .{ .name = "font-assets", .module = font_assets_dep.module("font-assets") },
        },
    });

    if (target.result.cpu.arch != .wasm32) {
        // Creates a step for unit testing. This only builds the test executable
        // but does not run it.
        const unit_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        var iter = module.import_table.iterator();
        while (iter.next()) |e| {
            unit_tests.root_module.addImport(e.key_ptr.*, e.value_ptr.*);
        }

        // Exposes a `test` step to the `zig build --help` menu, providing a way for the user to
        // request running the unit tests.
        const run_unit_tests = b.addRunArtifact(unit_tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);

        // TODO: autodoc segfaults the build if we have this enabled
        // https://github.com/hexops/mach/issues/1145
        //
        // const install_docs = b.addInstallDirectory(.{
        //     .source_dir = unit_tests.getEmittedDocs(),
        //     .install_dir = .prefix, // default build output prefix, ./zig-out
        //     .install_subdir = "docs",
        // });
        // const docs_step = b.step("docs", "Generate API docs");
        // docs_step.dependOn(&install_docs.step);
    }
}

pub const App = struct {
    b: *std.Build,
    mach_builder: *std.Build,
    name: []const u8,
    compile: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
    run: *std.Build.Step.Run,
    platform: core.App.Platform,
    core: core.App,

    pub fn init(
        app_builder: *std.Build,
        options: struct {
            name: []const u8,
            src: []const u8,
            target: std.Build.ResolvedTarget,
            optimize: std.builtin.OptimizeMode,
            custom_entrypoint: ?[]const u8 = null,
            deps: ?[]const std.Build.Module.Import = null,
            res_dirs: ?[]const []const u8 = null,
            watch_paths: ?[]const []const u8 = null,
            mach_builder: ?*std.Build = null,
            mach_mod: ?*std.Build.Module = null,
        },
    ) !App {
        const mach_builder = options.mach_builder orelse app_builder.dependency("mach", .{
            .target = options.target,
            .optimize = options.optimize,
        }).builder;
        const mach_mod = options.mach_mod orelse app_builder.dependency("mach", .{
            .target = options.target,
            .optimize = options.optimize,
        }).module("mach");

        var deps = std.ArrayList(std.Build.Module.Import).init(app_builder.allocator);
        if (options.deps) |v| try deps.appendSlice(v);
        try deps.append(.{ .name = "mach", .module = mach_mod });
        const mach_sysaudio_dep = mach_builder.dependency("mach_sysaudio", .{
            .target = options.target,
            .optimize = options.optimize,
        });
        try deps.append(.{ .name = "mach-sysaudio", .module = mach_sysaudio_dep.module("mach-sysaudio") });

        const mach_core_dep = mach_builder.dependency("mach_core", .{
            .target = options.target,
            .optimize = options.optimize,
        });
        const app = try core.App.init(app_builder, mach_core_dep.builder, .{
            .name = options.name,
            .src = options.src,
            .target = options.target,
            .optimize = options.optimize,
            .custom_entrypoint = options.custom_entrypoint,
            .deps = deps.items,
            .res_dirs = options.res_dirs,
            .watch_paths = options.watch_paths,
            .mach_core_mod = mach_core_dep.module("mach-core"),
        });
        return .{
            .core = app,
            .b = app.b,
            .mach_builder = mach_builder,
            .name = app.name,
            .compile = app.compile,
            .install = app.install,
            .run = app.run,
            .platform = app.platform,
        };
    }

    pub fn link(app: *const App) !void {
        // TODO: basisu support in wasm
        if (app.platform != .web) {
            app.compile.linkLibrary(app.mach_builder.dependency("mach_basisu", .{
                .target = app.compile.root_module.resolved_target.?,
                .optimize = app.compile.root_module.optimize.?,
            }).artifact("mach-basisu"));
        }
    }
};

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}

comptime {
    const supported_zig = std.SemanticVersion.parse("0.12.0-dev.2063+804cee3b9") catch unreachable;
    if (builtin.zig_version.order(supported_zig) != .eq) {
        @compileError(std.fmt.comptimePrint("unsupported Zig version ({}). Required Zig version 2024.1.0-mach: https://machengine.org/about/nominated-zig/#202410-mach", .{builtin.zig_version}));
    }
}
