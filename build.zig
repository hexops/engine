const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("mach_glfw");
const gpu = @import("mach_gpu");
const sysgpu = @import("mach_sysgpu");

pub const SysgpuBackend = enum {
    default,
    webgpu,
    d3d12,
    metal,
    vulkan,
    opengl,
};

/// Examples:
///
/// `zig build` -> builds all of Mach
/// `zig build test` -> runs all tests
///
/// ## (optional) minimal dependency fetching
///
/// By default, all Mach dependencies will be added to the build. If you only depend on a specific
/// part of Mach, then you can opt to have only the dependencies you need fetched as part of the
/// build:
///
/// ```
/// b.dependency("mach", .{
///   .target = target,
///   .optimize = optimize,
///   .core = true,
///   .sysaudio = true,
/// });
/// ```
///
/// The presense of `.core = true` and `.sysaudio = true` indicate Mach should add the dependencies
/// required by `@import("mach").core` and `@import("mach").sysaudio` to the build. You can use this
/// option with the following:
///
/// * core (also implies sysgpu)
/// * sysaudio
/// * sysgpu
///
/// Note that Zig's dead code elimination and, more importantly, lazy code evaluation means that
/// you really only pay for the parts of `@import("mach")` that you use/reference.
pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const core_deps = b.option(bool, "core", "build core specifically");
    const sysaudio_deps = b.option(bool, "sysaudio", "build sysaudio specifically");
    const sysgpu_deps = b.option(bool, "sysgpu", "build sysgpu specifically");
    const sysgpu_backend = b.option(SysgpuBackend, "sysgpu_backend", "sysgpu API backend") orelse .default;
    const core_platform = b.option(CoreApp.Platform, "core_platform", "mach core platform to use") orelse CoreApp.Platform.fromTarget(target.result);

    const want_mach = core_deps == null and sysaudio_deps == null and sysgpu_deps == null;
    const want_core = want_mach or (core_deps orelse false);
    const want_sysaudio = want_mach or (sysaudio_deps orelse false);
    const want_sysgpu = want_mach or want_core or (sysgpu_deps orelse false);

    const build_options = b.addOptions();
    build_options.addOption(bool, "want_mach", want_mach);
    build_options.addOption(bool, "want_core", want_core);
    build_options.addOption(bool, "want_sysaudio", want_sysaudio);
    build_options.addOption(bool, "want_sysgpu", want_sysgpu);
    build_options.addOption(SysgpuBackend, "sysgpu_backend", sysgpu_backend);
    build_options.addOption(CoreApp.Platform, "core_platform", core_platform);

    const module = b.addModule("mach", .{
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = optimize,
        .target = target,
    });
    module.addImport("build-options", build_options.createModule());
    if (want_mach) {
        // Linux gamemode requires libc.
        if (target.result.os.tag == .linux) module.link_libc = true;

        // TODO(Zig 2024.03): use b.lazyDependency
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

        module.addImport("mach-basisu", mach_basisu_dep.module("mach-basisu"));
        module.addImport("mach-freetype", mach_freetype_dep.module("mach-freetype"));
        module.addImport("mach-harfbuzz", mach_freetype_dep.module("mach-harfbuzz"));
        module.addImport("mach-sysjs", mach_sysjs_dep.module("mach-sysjs"));
        module.addImport("font-assets", font_assets_dep.module("font-assets"));
    }
    if (want_core) {
        const mach_gpu_dep = b.dependency("mach_gpu", .{
            .target = target,
            .optimize = optimize,
        });
        module.addImport("mach-gpu", mach_gpu_dep.module("mach-gpu"));

        if (target.result.cpu.arch == .wasm32) {
            const sysjs_dep = b.dependency("mach_sysjs", .{
                .target = target,
                .optimize = optimize,
            });
            module.addImport("mach-sysjs", sysjs_dep.module("mach-sysjs"));
        } else {
            const mach_glfw_dep = b.dependency("mach_glfw", .{
                .target = target,
                .optimize = optimize,
            });
            const x11_headers_dep = b.dependency("x11_headers", .{
                .target = target,
                .optimize = optimize,
            });
            const wayland_headers_dep = b.dependency("wayland_headers", .{
                .target = target,
                .optimize = optimize,
            });
            module.addImport("mach-glfw", mach_glfw_dep.module("mach-glfw"));
            module.linkLibrary(x11_headers_dep.artifact("x11-headers"));
            module.linkLibrary(wayland_headers_dep.artifact("wayland-headers"));
            module.addCSourceFile(.{ .file = .{ .path = "src/core/platform/wayland/wayland.c" } });
        }
        try buildCoreExamples(b, optimize, target, module, core_platform);
    }
    if (want_sysaudio) {
        // Can build sysaudio examples if desired, then.
        inline for ([_][]const u8{
            "sine",
            "record",
        }) |example| {
            const example_exe = b.addExecutable(.{
                .name = "sysaudio-" ++ example,
                .root_source_file = .{ .path = "src/sysaudio/examples/" ++ example ++ ".zig" },
                .target = target,
                .optimize = optimize,
            });
            example_exe.root_module.addImport("mach", module);
            addPaths(&example_exe.root_module);
            b.installArtifact(example_exe);

            const example_compile_step = b.step("sysaudio-" ++ example, "Compile 'sysaudio-" ++ example ++ "' example");
            example_compile_step.dependOn(b.getInstallStep());

            const example_run_cmd = b.addRunArtifact(example_exe);
            example_run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| example_run_cmd.addArgs(args);

            const example_run_step = b.step("run-sysaudio-" ++ example, "Run '" ++ example ++ "' example");
            example_run_step.dependOn(&example_run_cmd.step);
        }

        // Add sysaudio dependencies to the module.
        // TODO(Zig 2024.03): use b.lazyDependency
        const mach_sysjs_dep = b.dependency("mach_sysjs", .{
            .target = target,
            .optimize = optimize,
        });
        const mach_objc_dep = b.dependency("mach_objc", .{
            .target = target,
            .optimize = optimize,
        });
        module.addImport("sysjs", mach_sysjs_dep.module("mach-sysjs"));
        module.addImport("objc", mach_objc_dep.module("mach-objc"));

        if (target.result.isDarwin()) {
            // Transitive dependencies, explicit linkage of these works around
            // ziglang/zig#17130
            module.linkSystemLibrary("objc", .{});

            // Direct dependencies
            module.linkFramework("AudioToolbox", .{});
            module.linkFramework("CoreFoundation", .{});
            module.linkFramework("CoreAudio", .{});
        }
        if (target.result.os.tag == .linux) {
            // TODO(Zig 2024.03): use b.lazyDependency
            const linux_audio_headers_dep = b.dependency("linux_audio_headers", .{
                .target = target,
                .optimize = optimize,
            });
            module.link_libc = true;
            module.linkLibrary(linux_audio_headers_dep.artifact("linux-audio-headers"));

            // TODO: for some reason this is not functional, a Zig bug (only when using this Zig package
            // externally):
            //
            // module.addCSourceFile(.{
            //     .file = .{ .path = "src/pipewire/sysaudio.c" },
            //     .flags = &.{"-std=gnu99"},
            // });
            //
            // error: unable to check cache: stat file '/Volumes/data/hexops/mach-flac/zig-cache//Volumes/data/hexops/mach-flac/src/pipewire/sysaudio.c' failed: FileNotFound
            //
            // So instead we do this:
            const lib = b.addStaticLibrary(.{
                .name = "sysaudio-pipewire",
                .target = target,
                .optimize = optimize,
            });
            lib.linkLibC();
            lib.addCSourceFile(.{
                .file = .{ .path = "src/pipewire/sysaudio.c" },
                .flags = &.{"-std=gnu99"},
            });
            lib.linkLibrary(linux_audio_headers_dep.artifact("linux-audio-headers"));
            module.linkLibrary(lib);
        }
    }
    if (want_sysgpu) {
        // TODO(Zig 2024.03): use b.lazyDependency
        const vulkan_dep = b.dependency("vulkan_zig_generated", .{});
        const mach_objc_dep = b.dependency("mach_objc", .{
            .target = target,
            .optimize = optimize,
        });
        module.addImport("vulkan", vulkan_dep.module("vulkan-zig-generated"));
        module.addImport("objc", mach_objc_dep.module("mach-objc"));
        linkSysgpu(b, module);

        const lib = b.addStaticLibrary(.{
            .name = "mach-sysgpu",
            .root_source_file = b.addWriteFiles().add("empty.c", ""),
            .target = target,
            .optimize = optimize,
        });
        var iter = module.import_table.iterator();
        while (iter.next()) |e| {
            lib.root_module.addImport(e.key_ptr.*, e.value_ptr.*);
        }
        linkSysgpu(b, &lib.root_module);
        addPaths(&lib.root_module);
        b.installArtifact(lib);
    }

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
        addPaths(&unit_tests.root_module);

        // Exposes a `test` step to the `zig build --help` menu, providing a way for the user to
        // request running the unit tests.
        const run_unit_tests = b.addRunArtifact(unit_tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);

        if (want_sysgpu) linkSysgpu(b, &unit_tests.root_module);
    }
}

pub const App = struct {
    b: *std.Build,
    mach_builder: *std.Build,
    name: []const u8,
    compile: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
    run: *std.Build.Step.Run,
    platform: CoreApp.Platform,
    core: CoreApp,

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

        const app = try CoreApp.init(app_builder, mach_builder.builder, .{
            .name = options.name,
            .src = options.src,
            .target = options.target,
            .optimize = options.optimize,
            .custom_entrypoint = options.custom_entrypoint,
            .deps = deps.items,
            .res_dirs = options.res_dirs,
            .watch_paths = options.watch_paths,
            .mach_mod = mach_mod,
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
            addPaths(app.compile);
        }
    }
};

pub const CoreApp = struct {
    b: *std.Build,
    name: []const u8,
    compile: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
    run: *std.Build.Step.Run,
    platform: Platform,
    res_dirs: ?[]const []const u8,
    watch_paths: ?[]const []const u8,

    pub const Platform = enum {
        glfw,
        x11,
        wayland,
        web,

        pub fn fromTarget(target: std.Target) Platform {
            if (target.cpu.arch == .wasm32) return .web;
            return .glfw;
        }
    };

    pub fn init(
        app_builder: *std.Build,
        core_builder: *std.Build,
        options: struct {
            name: []const u8,
            src: []const u8,
            target: std.Build.ResolvedTarget,
            optimize: std.builtin.OptimizeMode,
            custom_entrypoint: ?[]const u8 = null,
            deps: ?[]const std.Build.Module.Import = null,
            res_dirs: ?[]const []const u8 = null,
            watch_paths: ?[]const []const u8 = null,
            mach_mod: ?*std.Build.Module = null,
            platform: ?Platform,
        },
    ) !CoreApp {
        const target = options.target.result;
        const platform = options.platform orelse Platform.fromTarget(target);

        var imports = std.ArrayList(std.Build.Module.Import).init(app_builder.allocator);

        const mach_mod = options.mach_mod orelse app_builder.dependency("mach", .{
            .target = options.target,
            .optimize = options.optimize,
        }).module("mach");
        try imports.append(.{
            .name = "mach",
            .module = mach_mod,
        });

        if (options.deps) |app_deps| try imports.appendSlice(app_deps);

        const app_module = app_builder.createModule(.{
            .root_source_file = .{ .path = options.src },
            .imports = try imports.toOwnedSlice(),
        });

        // Tell mach about the chosen platform
        const platform_options = app_builder.addOptions();
        platform_options.addOption(Platform, "platform", platform);
        mach_mod.addOptions("platform_options", platform_options);

        const compile = blk: {
            if (platform == .web) {
                // wasm libraries should go into zig-out/www/
                app_builder.lib_dir = app_builder.fmt("{s}/www", .{app_builder.install_path});

                const lib = app_builder.addStaticLibrary(.{
                    .name = options.name,
                    .root_source_file = .{ .path = options.custom_entrypoint orelse sdkPath("/src/core/platform/wasm/entrypoint.zig") },
                    .target = options.target,
                    .optimize = options.optimize,
                });
                lib.rdynamic = true;

                break :blk lib;
            } else {
                const exe = app_builder.addExecutable(.{
                    .name = options.name,
                    .root_source_file = .{ .path = options.custom_entrypoint orelse sdkPath("/src/core/platform/native_entrypoint.zig") },
                    .target = options.target,
                    .optimize = options.optimize,
                });
                // TODO(core): figure out why we need to disable LTO: https://github.com/hexops/mach/issues/597
                exe.want_lto = false;

                break :blk exe;
            }
        };

        compile.root_module.addImport("mach", mach_mod);
        compile.root_module.addImport("app", app_module);

        // Installation step
        app_builder.installArtifact(compile);
        const install = app_builder.addInstallArtifact(compile, .{});
        if (options.res_dirs) |res_dirs| {
            for (res_dirs) |res| {
                const install_res = app_builder.addInstallDirectory(.{
                    .source_dir = .{ .path = res },
                    .install_dir = install.dest_dir.?,
                    .install_subdir = std.fs.path.basename(res),
                    .exclude_extensions = &.{},
                });
                install.step.dependOn(&install_res.step);
            }
        }
        if (platform == .web) {
            inline for (.{ sdkPath("/src/core/platform/wasm/mach.js"), @import("mach_sysjs").getJSPath() }) |js| {
                const install_js = app_builder.addInstallFileWithDir(
                    .{ .path = js },
                    std.Build.InstallDir{ .custom = "www" },
                    std.fs.path.basename(js),
                );
                install.step.dependOn(&install_js.step);
            }
        }

        // Link dependencies
        if (platform != .web) {
            link(core_builder, compile, &compile.root_module);
        }

        const run = app_builder.addRunArtifact(compile);
        run.step.dependOn(&install.step);
        return .{
            .b = app_builder,
            .compile = compile,
            .install = install,
            .run = run,
            .name = options.name,
            .platform = platform,
            .res_dirs = options.res_dirs,
            .watch_paths = options.watch_paths,
        };
    }
};

// TODO(sysgpu): remove this once we switch to sysgpu fully
pub fn link(core_builder: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module) void {
    gpu.link(core_builder.dependency("mach_gpu", .{
        .target = step.root_module.resolved_target orelse core_builder.host,
        .optimize = step.root_module.optimize.?,
    }).builder, step, mod, .{}) catch unreachable;
}

fn linkSysgpu(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;

    const target = module.resolved_target.?.result;
    if (target.isDarwin()) {
        module.linkSystemLibrary("objc", .{});
        module.linkFramework("AppKit", .{});
        module.linkFramework("CoreGraphics", .{});
        module.linkFramework("Foundation", .{});
        module.linkFramework("Metal", .{});
        module.linkFramework("QuartzCore", .{});
    }
    if (target.os.tag == .windows) {
        module.linkSystemLibrary("d3d12", .{});
        module.linkSystemLibrary("d3dcompiler_47", .{});
        module.linkSystemLibrary("opengl32", .{});
        module.linkLibrary(b.dependency("direct3d_headers", .{
            .target = module.resolved_target orelse b.host,
            .optimize = module.optimize.?,
        }).artifact("direct3d-headers"));
        @import("direct3d_headers").addLibraryPathToModule(module);
        module.linkLibrary(b.dependency("opengl_headers", .{
            .target = module.resolved_target orelse b.host,
            .optimize = module.optimize.?,
        }).artifact("opengl-headers"));
    }

    module.linkLibrary(b.dependency("spirv_cross", .{
        .target = module.resolved_target orelse b.host,
        .optimize = module.optimize.?,
    }).artifact("spirv-cross"));
    module.linkLibrary(b.dependency("spirv_tools", .{
        .target = module.resolved_target orelse b.host,
        .optimize = module.optimize.?,
    }).artifact("spirv-opt"));
}

pub fn addPaths(mod: *std.Build.Module) void {
    if (mod.resolved_target.?.result.isDarwin()) @import("xcode_frameworks").addPaths(mod);
}

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

fn buildCoreExamples(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    mach_mod: *std.Build.Module,
    platform: CoreApp.Platform,
) !void {
    try ensureDependencies(b.allocator);

    const Dependency = enum {
        zigimg,
        model3d,
        assets,

        pub fn dependency(
            dep: @This(),
            b2: *std.Build,
            target2: std.Build.ResolvedTarget,
            optimize2: std.builtin.OptimizeMode,
        ) std.Build.Module.Import {
            const path = switch (dep) {
                .zigimg => "src/core/examples/libs/zigimg/zigimg.zig",
                .assets => return std.Build.Module.Import{
                    .name = "assets",
                    .module = b2.dependency("mach_core_example_assets", .{
                        .target = target2,
                        .optimize = optimize2,
                    }).module("mach-core-example-assets"),
                },
                .model3d => return std.Build.Module.Import{
                    .name = "model3d",
                    .module = b2.dependency("mach_model3d", .{
                        .target = target2,
                        .optimize = optimize2,
                    }).module("mach-model3d"),
                },
            };
            return std.Build.Module.Import{
                .name = @tagName(dep),
                .module = b2.createModule(.{ .root_source_file = .{ .path = path } }),
            };
        }
    };

    inline for ([_]struct {
        name: []const u8,
        deps: []const Dependency = &.{},
        std_platform_only: bool = false,
        sysgpu: bool = false,
    }{
        .{ .name = "wasm-test" },
        .{ .name = "triangle" },
        .{ .name = "triangle-msaa" },
        .{ .name = "clear-color" },
        .{ .name = "procedural-primitives" },
        .{ .name = "boids" },
        .{ .name = "rotating-cube" },
        .{ .name = "pixel-post-process" },
        .{ .name = "two-cubes" },
        .{ .name = "instanced-cube" },
        .{ .name = "gen-texture-light" },
        .{ .name = "fractal-cube" },
        .{ .name = "map-async" },
        .{ .name = "rgb-quad" },
        .{
            .name = "pbr-basic",
            .deps = &.{ .model3d, .assets },
            .std_platform_only = true,
        },
        .{
            .name = "deferred-rendering",
            .deps = &.{ .model3d, .assets },
            .std_platform_only = true,
        },
        .{ .name = "textured-cube", .deps = &.{ .zigimg, .assets } },
        .{ .name = "textured-quad", .deps = &.{ .zigimg, .assets } },
        .{ .name = "sprite2d", .deps = &.{ .zigimg, .assets } },
        .{ .name = "image", .deps = &.{ .zigimg, .assets } },
        .{ .name = "image-blur", .deps = &.{ .zigimg, .assets } },
        .{ .name = "cubemap", .deps = &.{ .zigimg, .assets } },

        // sysgpu
        .{ .name = "boids", .sysgpu = true },
        .{ .name = "clear-color", .sysgpu = true },
        .{ .name = "cubemap", .deps = &.{ .zigimg, .assets }, .sysgpu = true },
        .{ .name = "deferred-rendering", .deps = &.{ .model3d, .assets }, .std_platform_only = true, .sysgpu = true },
        .{ .name = "fractal-cube", .sysgpu = true },
        .{ .name = "gen-texture-light", .sysgpu = true },
        .{ .name = "image-blur", .deps = &.{ .zigimg, .assets }, .sysgpu = true },
        .{ .name = "instanced-cube", .sysgpu = true },
        .{ .name = "map-async", .sysgpu = true },
        .{ .name = "pbr-basic", .deps = &.{ .model3d, .assets }, .std_platform_only = true, .sysgpu = true },
        .{ .name = "pixel-post-process", .sysgpu = true },
        .{ .name = "procedural-primitives", .sysgpu = true },
        .{ .name = "rotating-cube", .sysgpu = true },
        .{ .name = "sprite2d", .deps = &.{ .zigimg, .assets }, .sysgpu = true },
        .{ .name = "image", .deps = &.{ .zigimg, .assets }, .sysgpu = true },
        .{ .name = "textured-cube", .deps = &.{ .zigimg, .assets }, .sysgpu = true },
        .{ .name = "textured-quad", .deps = &.{ .zigimg, .assets }, .sysgpu = true },
        .{ .name = "triangle", .sysgpu = true },
        .{ .name = "triangle-msaa", .sysgpu = true },
        .{ .name = "two-cubes", .sysgpu = true },
        .{ .name = "rgb-quad", .sysgpu = true },
    }) |example| {
        // FIXME: this is workaround for a problem that some examples
        // (having the std_platform_only=true field) as well as zigimg
        // uses IO and depends on gpu-dawn which is not supported
        // in freestanding environments. So break out of this loop
        // as soon as any such examples is found. This does means that any
        // example which works on wasm should be placed before those who dont.
        if (example.std_platform_only)
            if (target.result.cpu.arch == .wasm32)
                break;

        var deps = std.ArrayList(std.Build.Module.Import).init(b.allocator);
        try deps.append(std.Build.Module.Import{
            .name = "zmath",
            .module = b.createModule(.{
                .root_source_file = .{ .path = "src/core/examples/zmath.zig" },
            }),
        });
        for (example.deps) |d| try deps.append(d.dependency(b, target, optimize));
        const cmd_name = if (example.sysgpu) "sysgpu-" ++ example.name else example.name;
        const app = try CoreApp.init(
            b,
            b,
            .{
                .name = "core-" ++ cmd_name,
                .src = if (example.sysgpu)
                    "src/core/examples/sysgpu/" ++ example.name ++ "/main.zig"
                else
                    "src/core/examples/" ++ example.name ++ "/main.zig",
                .target = target,
                .optimize = optimize,
                .deps = deps.items,
                .watch_paths = if (example.sysgpu)
                    &.{"src/core/examples/sysgpu/" ++ example.name}
                else
                    &.{"src/core/examples/" ++ example.name},
                .mach_mod = mach_mod,
                .platform = platform,
            },
        );

        for (example.deps) |dep| switch (dep) {
            .model3d => app.compile.linkLibrary(b.dependency("mach_model3d", .{
                .target = target,
                .optimize = optimize,
            }).artifact("mach-model3d")),
            else => {},
        };

        const install_step = b.step("core-" ++ cmd_name, "Install core-" ++ cmd_name);
        install_step.dependOn(&app.install.step);
        b.getInstallStep().dependOn(install_step);

        const run_step = b.step("run-core-" ++ cmd_name, "Run core-" ++ cmd_name);
        run_step.dependOn(&app.run.step);
    }
}

// TODO(Zig 2024.03): use b.lazyDependency
fn ensureDependencies(allocator: std.mem.Allocator) !void {
    try optional_dependency.ensureGitRepoCloned(
        allocator,
        "https://github.com/slimsag/zigimg",
        "ad6ad042662856f55a4d67499f1c4606c9951031",
        sdkPath("/src/core/examples/libs/zigimg"),
    );
}

// TODO(Zig 2024.03): use b.lazyDependency
const optional_dependency = struct {
    fn ensureGitRepoCloned(allocator: std.mem.Allocator, clone_url: []const u8, revision: []const u8, dir: []const u8) !void {
        if (xIsEnvVarTruthy(allocator, "NO_ENSURE_SUBMODULES") or xIsEnvVarTruthy(allocator, "NO_ENSURE_GIT")) {
            return;
        }

        xEnsureGit(allocator);

        if (std.fs.openDirAbsolute(dir, .{})) |_| {
            const current_revision = try xGetCurrentGitRevision(allocator, dir);
            if (!std.mem.eql(u8, current_revision, revision)) {
                // Reset to the desired revision
                xExec(allocator, &[_][]const u8{ "git", "fetch" }, dir) catch |err| std.debug.print("warning: failed to 'git fetch' in {s}: {s}\n", .{ dir, @errorName(err) });
                try xExec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
                try xExec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
            }
            return;
        } else |err| return switch (err) {
            error.FileNotFound => {
                std.log.info("cloning required dependency..\ngit clone {s} {s}..\n", .{ clone_url, dir });

                try xExec(allocator, &[_][]const u8{ "git", "clone", "-c", "core.longpaths=true", clone_url, dir }, ".");
                try xExec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
                try xExec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
                return;
            },
            else => err,
        };
    }

    fn xExec(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !void {
        var child = std.ChildProcess.init(argv, allocator);
        child.cwd = cwd;
        _ = try child.spawnAndWait();
    }

    fn xGetCurrentGitRevision(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
        const result = try std.ChildProcess.run(.{ .allocator = allocator, .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = cwd });
        allocator.free(result.stderr);
        if (result.stdout.len > 0) return result.stdout[0 .. result.stdout.len - 1]; // trim newline
        return result.stdout;
    }

    fn xEnsureGit(allocator: std.mem.Allocator) void {
        const argv = &[_][]const u8{ "git", "--version" };
        const result = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = argv,
            .cwd = ".",
        }) catch { // e.g. FileNotFound
            std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
            std.process.exit(1);
        };
        defer {
            allocator.free(result.stderr);
            allocator.free(result.stdout);
        }
        if (result.term.Exited != 0) {
            std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
            std.process.exit(1);
        }
    }

    fn xIsEnvVarTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
        if (std.process.getEnvVarOwned(allocator, name)) |truthy| {
            defer allocator.free(truthy);
            if (std.mem.eql(u8, truthy, "true")) return true;
            return false;
        } else |_| {
            return false;
        }
    }
};
