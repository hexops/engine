const std = @import("std");
const testing = std.testing;
const StructField = std.builtin.Type.StructField;

const EntityID = @import("entities.zig").EntityID;

/// Verifies that T matches the expected layout of an ECS module
pub fn Module(comptime T: type) type {
    if (@typeInfo(T) != .Struct) @compileError("Module must be a struct type. Found:" ++ @typeName(T));
    if (!@hasDecl(T, "name")) @compileError("Module must have `pub const name = .foobar;`");
    if (@typeInfo(@TypeOf(T.name)) != .EnumLiteral) @compileError("Module must have `pub const name = .foobar;`, found type:" ++ @typeName(T.name));
    if (@hasDecl(T, "components")) {
        if (@typeInfo(T.components) != .Struct) @compileError("Module.components must be `pub const components = struct { ... };`, found type:" ++ @typeName(T.components));
    }
    return T;
}

fn NamespacedComponents(comptime modules: anytype) type {
    var fields: []const StructField = &[0]StructField{};
    inline for (modules) |M| {
        const components = if (@hasDecl(M, "components")) M.components else struct {};
        fields = fields ++ [_]std.builtin.Type.StructField{.{
            .name = @tagName(M.name),
            .type = type,
            .default_value = &components,
            .is_comptime = true,
            .alignment = @alignOf(@TypeOf(components)),
        }};
    }

    // Builtin components
    const entity_components = struct {
        pub const id = EntityID;
    };
    fields = fields ++ [_]std.builtin.Type.StructField{.{
        .name = "entity",
        .type = type,
        .default_value = &entity_components,
        .is_comptime = true,
        .alignment = @alignOf(@TypeOf(entity_components)),
    }};

    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

fn NamespacedState(comptime modules: anytype) type {
    var fields: []const StructField = &[0]StructField{};
    inline for (modules) |M| {
        const state_fields = std.meta.fields(M);
        const State = if (state_fields.len > 0) @Type(.{
            .Struct = .{
                .layout = .Auto,
                .is_tuple = false,
                .fields = state_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
            },
        }) else struct {};
        fields = fields ++ [_]std.builtin.Type.StructField{.{
            .name = @tagName(M.name),
            .type = State,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(State),
        }};
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

pub fn Modules(comptime mods: anytype) type {
    inline for (mods) |M| _ = Module(M);
    return struct {
        pub const modules = mods;

        pub const components = NamespacedComponents(mods){};

        pub const State = NamespacedState(mods);
    };
}

test "module" {
    _ = Module(struct {
        // Physics module state
        pointer: usize,

        // Globally unique module name
        pub const name = .engine_physics;

        /// Physics module components
        pub const components = struct {
            /// A location component
            pub const location = @Vector(3, f32);
        };

        pub fn tick(adapter: anytype) void {
            _ = adapter;
        }
    });
}

test "modules" {
    const Physics = Module(struct {
        // Physics module state
        pointer: usize,

        // Globally unique module name
        pub const name = .engine_physics;

        /// Physics module components
        pub const components = struct {
            /// A location component
            pub const location = @Vector(3, f32);
        };

        pub fn tick(adapter: anytype) void {
            _ = adapter;
        }
    });

    const Renderer = Module(struct {
        pub const name = .engine_renderer;

        /// Renderer module components
        pub const components = struct {};

        pub fn tick(adapter: anytype) void {
            _ = adapter;
        }
    });

    const Sprite2D = Module(struct {
        pub const name = .engine_sprite2d;
    });

    const modules = Modules(.{
        Physics,
        Renderer,
        Sprite2D,
    });
    testing.refAllDeclsRecursive(modules);
    testing.refAllDeclsRecursive(Physics);
    testing.refAllDeclsRecursive(Renderer);
    testing.refAllDeclsRecursive(Sprite2D);

    // access namespaced components
    try testing.expectEqual(Physics.components.location, modules.components.engine_physics.location);
    try testing.expectEqual(Renderer.components, modules.components.engine_renderer);

    // implicitly generated
    _ = modules.components.entity.id;

    Physics.tick(null);
}
