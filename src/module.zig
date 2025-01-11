const std = @import("std");
const mach = @import("main.zig");
const StringTable = @import("StringTable.zig");
const Graph = @import("graph.zig").Graph;

/// An ID representing a mach object. This is an opaque identifier which effectively encodes:
///
/// * An array index that can be used to O(1) lookup the actual data / struct fields of the object.
/// * The generation (or 'version') of the object, enabling detecting use-after-object-delete in
///   many (but not all) cases.
/// * Which module the object came from, allowing looking up type information or the module name
///   from ID alone.
/// * Which list of objects in a module the object came from, allowing looking up type information
///   or the object type name - which enables debugging and type safety when passing opaque IDs
///   around.
///
pub const ObjectID = u64;

const ObjectTypeID = u16;

const PackedObjectTypeID = packed struct(u16) {
    // 2^10 (1024) modules in an application
    module_name_id: u10,
    // 2^6 (64) lists of objects per module
    object_name_id: u6,
};

pub const ObjectsOptions = struct {
    /// If set to true, Mach will track when fields are set using the setField/setAll
    /// methods using a bitset with one bit per field to indicate 'the field was set'.
    /// You can get this information by calling `.updated(.field_name)`
    /// Note that calling `.updated(.field_name) will also set the flag back to false.
    track_fields: bool = false,
};

pub fn Objects(options: ObjectsOptions, comptime T: type) type {
    return struct {
        internal: struct {
            allocator: std.mem.Allocator,

            /// Mutex to be held when operating on these objects.
            /// TODO(object): replace with RwLock and update website docs to indicate this
            mu: std.Thread.Mutex = .{},

            /// A registered ID indicating the type of objects being represented. This can be
            /// thought of as a hash of the module name + field name where this objects list is
            /// stored.
            type_id: ObjectTypeID,

            /// The actual object data
            data: std.MultiArrayList(T) = .{},

            /// Whether a given slot in data[i] is dead or not
            dead: std.bit_set.DynamicBitSetUnmanaged = .{},

            /// The current generation number of data[i], when data[i] becomes dead and then alive
            /// again, this number is incremented by one.
            generation: std.ArrayListUnmanaged(Generation) = .{},

            /// The recycling bin which tells which data indices are dead and can be reused.
            recycling_bin: std.ArrayListUnmanaged(Index) = .{},

            /// The number of objects that could not fit in the recycling bin and hence were thrown
            /// on the floor and forgotten about. This means there are dead items recorded by dead.set(index)
            /// which aren't in the recycling_bin, and the next call to new() may consider cleaning up.
            thrown_on_the_floor: u32 = 0,

            /// Global pointer to object relations graph
            graph: *Graph,

            /// A bitset used to track per-field changes. Only used if options.track_fields == true.
            updated: ?std.bit_set.DynamicBitSetUnmanaged = if (options.track_fields) .{} else null,
        },

        pub const IsMachObjects = void;

        const Generation = u16;
        const Index = u32;

        const PackedID = packed struct(u64) {
            type_id: ObjectTypeID,
            generation: Generation,
            index: Index,
        };

        pub const Slice = struct {
            index: Index,
            objs: *Objects(options, T),

            pub fn next(s: *Slice) ?ObjectID {
                const dead = &s.objs.internal.dead;
                const generation = &s.objs.internal.generation;
                const num_objects = generation.items.len;

                while (true) {
                    if (s.index == num_objects) {
                        s.index = 0;
                        return null;
                    }
                    defer s.index += 1;

                    if (!dead.isSet(s.index)) return @bitCast(PackedID{
                        .type_id = s.objs.internal.type_id,
                        .generation = generation.items[s.index],
                        .index = s.index,
                    });
                }
            }
        };

        /// Tries to acquire the mutex without blocking the caller's thread.
        /// Returns `false` if the calling thread would have to block to acquire it.
        /// Otherwise, returns `true` and the caller should `unlock()` the Mutex to release it.
        pub fn tryLock(objs: *@This()) bool {
            return objs.internal.mu.tryLock();
        }

        /// Acquires the mutex, blocking the caller's thread until it can.
        /// It is undefined behavior if the mutex is already held by the caller's thread.
        /// Once acquired, call `unlock()` on the Mutex to release it.
        pub fn lock(objs: *@This()) void {
            objs.internal.mu.lock();
        }

        /// Releases the mutex which was previously acquired with `lock()` or `tryLock()`.
        /// It is undefined behavior if the mutex is unlocked from a different thread that it was locked from.
        pub fn unlock(objs: *@This()) void {
            objs.internal.mu.unlock();
        }

        pub fn new(objs: *@This(), value: T) std.mem.Allocator.Error!ObjectID {
            const allocator = objs.internal.allocator;
            const data = &objs.internal.data;
            const dead = &objs.internal.dead;
            const generation = &objs.internal.generation;
            const recycling_bin = &objs.internal.recycling_bin;

            // The recycling bin should always be big enough, but we check at this point if 10% of
            // all objects have been thrown on the floor. If they have, we find them and grow the
            // recycling bin to fit them.
            if (objs.internal.thrown_on_the_floor >= (data.len / 10)) {
                var iter = dead.iterator(.{ .kind = .set });
                dead_object_loop: while (iter.next()) |index| {
                    // We need to check if this index is already in the recycling bin since
                    // if it is, it could get recycled a second time while still
                    // in use.
                    for (recycling_bin.items) |recycled_index| {
                        if (index == recycled_index) continue :dead_object_loop;
                    }

                    // dead bitset contains data.capacity number of entries, we only care about ones that are in data.len range.
                    if (index > data.len - 1) break;
                    try recycling_bin.append(allocator, @intCast(index));
                }
                objs.internal.thrown_on_the_floor = 0;
            }

            if (recycling_bin.popOrNull()) |index| {
                // Reuse a free slot from the recycling bin.
                dead.unset(index);
                const gen = generation.items[index] + 1;
                generation.items[index] = gen;
                data.set(index, value);
                return @bitCast(PackedID{
                    .type_id = objs.internal.type_id,
                    .generation = gen,
                    .index = index,
                });
            }

            // Ensure we have space for the new object
            try data.ensureUnusedCapacity(allocator, 1);
            try dead.resize(allocator, data.capacity, false);
            try generation.ensureUnusedCapacity(allocator, 1);

            // If we are tracking fields, we need to resize the bitset to hold another object's fields
            if (objs.internal.updated) |*updated_fields| {
                try updated_fields.resize(allocator, data.capacity * @typeInfo(T).@"struct".fields.len, true);
            }

            const index = data.len;
            data.appendAssumeCapacity(value);
            dead.unset(index);
            generation.appendAssumeCapacity(0);

            return @bitCast(PackedID{
                .type_id = objs.internal.type_id,
                .generation = 0,
                .index = @intCast(index),
            });
        }

        /// Sets all fields of the given object to the given value.
        ///
        /// Unlike setAll(), this method does not respect any mach.Objects tracking
        /// options, so changes made to an object through this method will not be tracked.
        pub fn setValueRaw(objs: *@This(), id: ObjectID, value: T) void {
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "setValueRaw");
            data.set(unpacked.index, value);
        }

        /// Sets all fields of the given object to the given value.
        ///
        /// Unlike setAllRaw, this method respects mach.Objects tracking
        /// and changes made to an object through this method will be tracked.
        pub fn setValue(objs: *@This(), id: ObjectID, value: T) void {
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "setValue");
            data.set(unpacked.index, value);

            if (objs.internal.updated) |*updated_fields| {
                const updated_start = unpacked.index * @typeInfo(T).@"struct".fields.len;
                const updated_end = updated_start + @typeInfo(T).@"struct".fields.len;
                updated_fields.setRangeValue(.{ .start = @intCast(updated_start), .end = @intCast(updated_end) }, true);
            }
        }

        /// Sets a single field of the given object to the given value.
        ///
        /// Unlike set(), this method does not respect any mach.Objects tracking
        /// options, so changes made to an object through this method will not be tracked.
        pub fn setRaw(objs: *@This(), id: ObjectID, comptime field_name: std.meta.FieldEnum(T), value: std.meta.FieldType(T, field_name)) void {
            const data = &objs.internal.data;
            const unpacked = objs.validateAndUnpack(id, "setRaw");

            data.items(field_name)[unpacked.index] = value;
        }

        /// Sets a single field of the given object to the given value.
        ///
        /// Unlike setAllRaw, this method respects mach.Objects tracking
        /// and changes made to an object through this method will be tracked.
        pub fn set(objs: *@This(), id: ObjectID, comptime field_name: std.meta.FieldEnum(T), value: std.meta.FieldType(T, field_name)) void {
            const data = &objs.internal.data;
            const unpacked = objs.validateAndUnpack(id, "set");

            data.items(field_name)[unpacked.index] = value;

            if (options.track_fields)
                if (std.meta.fieldIndex(T, @tagName(field_name))) |field_index|
                    if (objs.internal.updated) |*updated_fields|
                        updated_fields.set(unpacked.index * @typeInfo(T).@"struct".fields.len + field_index);
        }

        /// Get a single field.
        pub fn get(objs: *@This(), id: ObjectID, comptime field_name: std.meta.FieldEnum(T)) std.meta.FieldType(T, field_name) {
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "get");
            return data.items(field_name)[unpacked.index];
        }

        /// Get all fields.
        pub fn getValue(objs: *@This(), id: ObjectID) T {
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "getValue");
            return data.get(unpacked.index);
        }

        pub fn delete(objs: *@This(), id: ObjectID) void {
            const data = &objs.internal.data;
            const dead = &objs.internal.dead;
            const recycling_bin = &objs.internal.recycling_bin;

            const unpacked = objs.validateAndUnpack(id, "delete");
            if (recycling_bin.items.len < recycling_bin.capacity) {
                recycling_bin.appendAssumeCapacity(unpacked.index);
            } else objs.internal.thrown_on_the_floor += 1;

            dead.set(unpacked.index);
            if (mach.is_debug) data.set(unpacked.index, undefined);
        }

        pub fn slice(objs: *@This()) Slice {
            return Slice{
                .index = 0,
                .objs = objs,
            };
        }

        /// Validates the given object is from this list (type check) and alive (not a use after delete
        /// situation.)
        fn validateAndUnpack(objs: *const @This(), id: ObjectID, comptime fn_name: []const u8) PackedID {
            const dead = &objs.internal.dead;
            const generation = &objs.internal.generation;

            // TODO(object): decide whether to disable safety checks like this in some conditions,
            // e.g. in release builds
            const unpacked: PackedID = @bitCast(id);
            if (unpacked.type_id != objs.internal.type_id) {
                @panic("mach: " ++ fn_name ++ "() called with object not from this list");
            }
            if (unpacked.generation != generation.items[unpacked.index]) {
                @panic("mach: " ++ fn_name ++ "() called with a dead object (use after delete, recycled slot)");
            }
            if (dead.isSet(unpacked.index)) {
                @panic("mach: " ++ fn_name ++ "() called with a dead object (use after delete)");
            }
            return unpacked;
        }

        /// If options have tracking enabled, this returns true when the given field has been set
        /// using the set() or setAll() methods. A subsequent call to .updated(), .anyUpdated(), etc.
        /// will return false until another set() or setAll() call is made.
        pub fn updated(objs: *@This(), id: ObjectID, field_name: anytype) bool {
            return objs.updatedOptions(id, field_name, false);
        }

        /// Same as updated(), but doesn't alter the behavior of subsequent .updated(), .anyUpdated(),
        /// etc. calls
        pub fn peekUpdated(objs: *@This(), id: ObjectID, field_name: anytype) bool {
            return objs.updatedOptions(id, field_name, true);
        }

        inline fn updatedOptions(objs: *@This(), id: ObjectID, field_name: anytype, comptime peek: bool) bool {
            if (!options.track_fields) return false;
            const unpacked = objs.validateAndUnpack(id, "updated");
            const field_index = std.meta.fieldIndex(T, @tagName(field_name)).?;
            const updated_fields = &(objs.internal.updated orelse return false);
            const updated_index = unpacked.index * @typeInfo(T).@"struct".fields.len + field_index;
            const updated_value = updated_fields.isSet(updated_index);
            if (!peek) updated_fields.unset(updated_index);
            return updated_value;
        }

        /// If options have tracking enabled, this returns true when any field has been set using
        /// the set() or setAll() methods. A subsequent call to .updated(), .anyUpdated(), etc. will
        /// return false until another set() or setAll() call is made.
        pub fn anyUpdated(objs: *@This(), id: ObjectID) bool {
            return objs.anyUpdatedOptions(id, false);
        }

        /// Same as anyUpdated(), but doesn't alter the behavior of subsequent .updated(), .anyUpdated(),
        /// etc. calls
        pub fn peekAnyUpdated(objs: *@This(), id: ObjectID) bool {
            return objs.anyUpdatedOptions(id, true);
        }

        inline fn anyUpdatedOptions(objs: *@This(), id: ObjectID, comptime peek: bool) bool {
            if (!options.track_fields) return false;
            const unpacked = objs.validateAndUnpack(id, "updated");
            const updated_fields = &(objs.internal.updated orelse return false);
            var any_updated = false;
            inline for (0..@typeInfo(T).@"struct".fields.len) |field_index| {
                const updated_index = unpacked.index * @typeInfo(T).@"struct".fields.len + field_index;
                const updated_value = updated_fields.isSet(updated_index);
                if (!peek) updated_fields.unset(updated_index);
                if (updated_value) any_updated = true;
            }
            return any_updated;
        }

        /// Tells if the given object is from this pool of objects. If it is, then it must also be
        /// alive/valid or else a panic will occur.
        pub fn is(objs: *const @This(), id: ObjectID) bool {
            const unpacked: PackedID = @bitCast(id);
            if (unpacked.type_id != objs.internal.type_id) return false;
            _ = objs.validateAndUnpack(id, "is");
            return true;
        }

        /// Get the parent of the child, or null.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn getParent(objs: *@This(), id: ObjectID) !?ObjectID {
            return objs.internal.graph.getParent(objs.internal.allocator, id);
        }

        /// Set the parent of the child, or no-op if already the case.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn setParent(objs: *@This(), id: ObjectID, parent: ?ObjectID) !void {
            try objs.internal.graph.setParent(objs.internal.allocator, id, parent orelse return objs.internal.graph.removeParent(objs.internal.allocator, id));
        }

        /// Get the children of the parent; returning a results.items slice which is read-only.
        /// Call results.deinit() when you are done to return memory to the graph's memory pool for
        /// reuse later.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn getChildren(objs: *@This(), id: ObjectID) !Graph.Results {
            return objs.internal.graph.getChildren(objs.internal.allocator, id);
        }

        /// Add the given child to the parent, or no-op if already the case.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn addChild(objs: *@This(), id: ObjectID, child: ObjectID) !void {
            return objs.internal.graph.addChild(objs.internal.allocator, id, child);
        }

        /// Remove the given child from the parent, or no-op if not the case.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn removeChild(objs: *@This(), id: ObjectID, child: ObjectID) !void {
            return objs.internal.graph.removeChild(objs.internal.allocator, id, child);
        }

        /// Queries the children of the given object ID (which may be any object, including one not
        /// in this list of objects - and finds the first child which would be from this list of
        /// objects.
        pub fn getFirstChildOfType(objs: *@This(), id: ObjectID) !?ObjectID {
            var children = try objs.getChildren(id);
            defer children.deinit();
            for (children.items) |child_id| {
                if (objs.is(child_id)) return child_id;
            }
            return null;
        }
    };
}

/// Unique identifier for every module in the program, including those only known at runtime.
pub const ModuleID = u32;

/// Unique identifier for a function within a single module, including those only known at runtime.
pub const ModuleFunctionID = u16;

/// Unique identifier for a function within a module, including those only known at runtime.
pub const FunctionID = struct { module_id: ModuleID, fn_id: ModuleFunctionID };

pub fn Mod(comptime M: type) type {
    return struct {
        pub const IsMachMod = void;

        pub const module_name = M.mach_module;
        pub const Module = M;

        id: ModFunctionIDs(M),
        _ctx: *anyopaque,
        _run: *const fn (ctx: *anyopaque, fn_id: FunctionID) void,

        pub fn run(r: *const @This(), fn_id: FunctionID) void {
            r._run(r._ctx, fn_id);
        }

        pub fn call(r: *const @This(), comptime f: ModuleFunctionName2(M)) void {
            const fn_id = @field(r.id, @tagName(f));
            r.run(fn_id);
        }
    };
}

pub fn ModFunctionIDs(comptime Module: type) type {
    var fields: []const std.builtin.Type.StructField = &[0]std.builtin.Type.StructField{};
    for (Module.mach_systems) |fn_name| {
        fields = fields ++ [_]std.builtin.Type.StructField{.{
            .name = @tagName(fn_name),
            .type = FunctionID,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(FunctionID),
        }};
    }
    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .is_tuple = false,
            .fields = fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

/// Enum describing all declarations for a given comptime-known module.
// TODO: unify with ModuleFunctionName
fn ModuleFunctionName2(comptime M: type) type {
    validate(M);
    var enum_fields: []const std.builtin.Type.EnumField = &[0]std.builtin.Type.EnumField{};
    var i: u32 = 0;
    inline for (M.mach_systems) |fn_tag| {
        // TODO: verify decls are Fn or mach.schedule() decl
        enum_fields = enum_fields ++ [_]std.builtin.Type.EnumField{.{ .name = @tagName(fn_tag), .value = i }};
        i += 1;
    }
    return @Type(.{
        .@"enum" = .{
            .tag_type = if (enum_fields.len > 0) std.math.IntFittingRange(0, enum_fields.len - 1) else u0,
            .fields = enum_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        },
    });
}

pub fn Modules(module_lists: anytype) type {
    inline for (moduleTuple(module_lists)) |module| {
        validate(module);
    }
    return struct {
        /// All modules
        pub const modules = moduleTuple(module_lists);

        /// Enum describing every module name compiled into the program.
        pub const ModuleName = NameEnum(modules);

        mods: ModulesByName(modules),

        module_names: StringTable = .{},
        object_names: StringTable = .{},
        graph: Graph,

        /// Enum describing all declarations for a given comptime-known module.
        fn ModuleFunctionName(comptime module_name: ModuleName) type {
            const module = @field(ModuleTypesByName(modules){}, @tagName(module_name));
            validate(module);

            var enum_fields: []const std.builtin.Type.EnumField = &[0]std.builtin.Type.EnumField{};
            var i: u32 = 0;
            inline for (module.mach_systems) |fn_tag| {
                // TODO: verify decls are Fn or mach.schedule() decl
                enum_fields = enum_fields ++ [_]std.builtin.Type.EnumField{.{ .name = @tagName(fn_tag), .value = i }};
                i += 1;
            }
            return @Type(.{
                .@"enum" = .{
                    .tag_type = if (enum_fields.len > 0) std.math.IntFittingRange(0, enum_fields.len - 1) else u0,
                    .fields = enum_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            });
        }

        pub fn init(m: *@This(), allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
            m.* = .{
                .mods = undefined,
                .graph = undefined,
            };
            try m.graph.init(allocator, .{
                // TODO(object): measured preallocations
                .queue_size = 32,
                .nodes_size = 32,
                .num_result_lists = 8,
                .result_list_size = 8,
            });

            // TODO(object): errdefer release allocations made in this loop
            inline for (@typeInfo(@TypeOf(m.mods)).@"struct".fields) |field| {
                // TODO(objects): module-state-init
                const Mod2 = @TypeOf(@field(m.mods, field.name));
                var mod: Mod2 = undefined;
                const module_name_id = try m.module_names.indexOrPut(allocator, @tagName(Mod2.mach_module));
                inline for (@typeInfo(@TypeOf(mod)).@"struct".fields) |mod_field| {
                    if (@typeInfo(mod_field.type) == .@"struct" and @hasDecl(mod_field.type, "IsMachObjects")) {
                        const object_name_id = try m.object_names.indexOrPut(allocator, mod_field.name);

                        // TODO: use packed struct(TypeID) here. Same thing, just get the type from central location
                        const object_type_id: u16 = @bitCast(PackedObjectTypeID{
                            .module_name_id = @intCast(module_name_id),
                            .object_name_id = @intCast(object_name_id),
                        });

                        @field(mod, mod_field.name).internal = .{
                            .allocator = allocator,
                            .type_id = object_type_id,
                            .graph = &m.graph,
                        };
                    }
                }
                @field(m.mods, field.name) = mod;
            }
        }

        pub fn deinit(m: *@This(), allocator: std.mem.Allocator) void {
            m.graph.deinit(allocator);
            // TODO: remainder of deinit
        }

        pub fn Module(module_tag_or_type: anytype) type {
            const module_name: ModuleName = blk: {
                if (@typeInfo(@TypeOf(module_tag_or_type)) == .enum_literal or @typeInfo(@TypeOf(module_tag_or_type)) == .@"enum") break :blk @as(ModuleName, module_tag_or_type);
                validate(module_tag_or_type);
                break :blk module_tag_or_type.mach_module;
            };

            const module = @field(ModuleTypesByName(modules){}, @tagName(module_name));
            validate(module);

            return struct {
                mods: *ModulesByName(modules),
                modules: *Modules(module_lists),

                pub const mod_name: ModuleName = module_name;

                pub fn getFunction(fn_name: ModuleFunctionName(mod_name)) FunctionID {
                    return .{
                        .module_id = @intFromEnum(mod_name),
                        .fn_id = @intFromEnum(fn_name),
                    };
                }

                pub fn run(
                    m: *const @This(),
                    comptime fn_name: ModuleFunctionName(module_name),
                ) void {
                    const debug_name = @tagName(module_name) ++ "." ++ @tagName(fn_name);
                    const f = @field(module, @tagName(fn_name));
                    const F = @TypeOf(f);

                    if (@typeInfo(F) == .@"struct" and @typeInfo(F).@"struct".is_tuple) {
                        // Run a list of functions instead of a single function
                        // TODO: verify this is a mach.schedule() decl
                        if (module_name != .app) @compileLog(module_name);
                        inline for (f) |schedule_entry| {
                            // TODO: unify with Modules(modules).get(M)
                            const callMod: Module(schedule_entry.@"0") = .{ .mods = m.mods, .modules = m.modules };
                            const callFn = @as(ModuleFunctionName(@TypeOf(callMod).mod_name), schedule_entry.@"1");
                            callMod.run(callFn);
                        }
                        return;
                    }

                    // Inject arguments
                    var args: std.meta.ArgsTuple(F) = undefined;
                    outer: inline for (@typeInfo(std.meta.ArgsTuple(F)).@"struct".fields) |arg| {
                        if (@typeInfo(arg.type) == .pointer and
                            @typeInfo(std.meta.Child(arg.type)) == .@"struct" and
                            comptime isValid(std.meta.Child(arg.type)))
                        {
                            // *Module argument
                            // TODO: better error if @field(m.mods, ...) fails ("module not registered")
                            @field(args, arg.name) = &@field(m.mods, @tagName(std.meta.Child(arg.type).mach_module));
                            continue :outer;
                        }
                        if (@typeInfo(arg.type) == .@"struct" and @hasDecl(arg.type, "IsMachMod")) {
                            const M = arg.type.Module;
                            var mv: Mod(M) = .{
                                .id = undefined,
                                ._ctx = m.modules,
                                ._run = (struct {
                                    pub fn run(ctx: *anyopaque, fn_id: FunctionID) void {
                                        const modules2: *Modules(module_lists) = @ptrCast(@alignCast(ctx));
                                        modules2.callDynamic(fn_id);
                                    }
                                }).run,
                            };
                            inline for (M.mach_systems) |m_fn_name| {
                                @field(mv.id, @tagName(m_fn_name)) = Module(M).getFunction(m_fn_name);
                            }
                            @field(args, arg.name) = mv;
                            continue :outer;
                        }
                        @compileError("mach: function " ++ debug_name ++ " has an invalid argument(" ++ arg.name ++ ") type: " ++ @typeName(arg.type));
                    }

                    const Ret = @typeInfo(F).@"fn".return_type orelse void;
                    switch (@typeInfo(Ret)) {
                        // TODO: define error handling of runnable functions
                        .error_union => @call(.auto, f, args) catch |err| std.debug.panic("error: {s}", .{@errorName(err)}),
                        else => @call(.auto, f, args),
                    }
                }
            };
        }

        pub fn get(m: *@This(), module_tag_or_type: anytype) Module(module_tag_or_type) {
            return .{ .mods = &m.mods, .modules = m };
        }

        pub fn callDynamic(m: *@This(), f: FunctionID) void {
            const module_name: ModuleName = @enumFromInt(f.module_id);
            switch (module_name) {
                inline else => |mod_name| {
                    const module_fn_name: ModuleFunctionName(mod_name) = @enumFromInt(f.fn_id);
                    const mod: Module(mod_name) = .{ .mods = &m.mods, .modules = m };
                    const module = @field(ModuleTypesByName(modules){}, @tagName(mod_name));
                    validate(module);

                    switch (module_fn_name) {
                        inline else => |fn_name| mod.run(fn_name),
                    }
                },
            }
        }
    };
}

/// Validates that the given struct is a Mach module.
fn validate(comptime module: anytype) void {
    if (!@hasDecl(module, "mach_module")) @compileError("mach: invalid module, missing `pub const mach_module = .foo_name;` declaration: " ++ @typeName(@TypeOf(module)));
    if (@typeInfo(@TypeOf(module.mach_module)) != .enum_literal) @compileError("mach: invalid module, expected `pub const mach_module = .foo_name;` declaration, found: " ++ @typeName(@TypeOf(module.mach_module)));
}

fn isValid(comptime module: anytype) bool {
    if (!@hasDecl(module, "mach_module")) return false;
    if (@typeInfo(@TypeOf(module.mach_module)) != .enum_literal) return false;
    return true;
}

/// Given a tuple of Mach module structs, returns an enum which has every possible comptime-known
/// module name.
fn NameEnum(comptime mods: anytype) type {
    var enum_fields: []const std.builtin.Type.EnumField = &[0]std.builtin.Type.EnumField{};
    for (mods, 0..) |module, i| {
        validate(module);
        enum_fields = enum_fields ++ [_]std.builtin.Type.EnumField{.{ .name = @tagName(module.mach_module), .value = i }};
    }
    return @Type(.{
        .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, enum_fields.len - 1),
            .fields = enum_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        },
    });
}

/// Given a tuple of module structs or module struct tuples:
///
/// ```
/// .{
///     .{ Baz, .{ Bar, Foo, .{ Fam } }, Bar },
///     Foo,
///     Bam,
///     .{ Foo, Bam },
/// }
/// ```
///
/// Returns a flat tuple, deduplicated:
///
/// .{ Baz, Bar, Foo, Fam, Bar, Bam }
///
fn moduleTuple(comptime tuple: anytype) ModuleTuple(tuple) {
    return ModuleTuple(tuple){};
}

/// Type-returning variant of merge()
fn ModuleTuple(comptime tuple: anytype) type {
    if (@typeInfo(@TypeOf(tuple)) != .@"struct" or !@typeInfo(@TypeOf(tuple)).@"struct".is_tuple) {
        @compileError("Expected to find a tuple, found: " ++ @typeName(@TypeOf(tuple)));
    }

    var tuple_fields: []const std.builtin.Type.StructField = &[0]std.builtin.Type.StructField{};
    loop: inline for (tuple) |elem| {
        if (@typeInfo(@TypeOf(elem)) == .type and @typeInfo(elem) == .@"struct") {
            // Struct type
            validate(elem);
            for (tuple_fields) |field| if (@as(*const type, @ptrCast(field.default_value.?)).* == elem)
                continue :loop;

            var num_buf: [128]u8 = undefined;
            tuple_fields = tuple_fields ++ [_]std.builtin.Type.StructField{.{
                .name = std.fmt.bufPrintZ(&num_buf, "{d}", .{tuple_fields.len}) catch unreachable,
                .type = type,
                .default_value = &elem,
                .is_comptime = true,
                .alignment = 0,
            }};
        } else if (@typeInfo(@TypeOf(elem)) == .@"struct" and @typeInfo(@TypeOf(elem)).@"struct".is_tuple) {
            // Nested tuple
            inline for (moduleTuple(elem)) |nested| {
                validate(nested);
                for (tuple_fields) |field| if (@as(*const type, @ptrCast(field.default_value.?)).* == nested)
                    continue :loop;

                var num_buf: [128]u8 = undefined;
                tuple_fields = tuple_fields ++ [_]std.builtin.Type.StructField{.{
                    .name = std.fmt.bufPrintZ(&num_buf, "{d}", .{tuple_fields.len}) catch unreachable,
                    .type = type,
                    .default_value = &nested,
                    .is_comptime = true,
                    .alignment = 0,
                }};
            }
        } else {
            @compileError("Expected to find a tuple or struct type, found: " ++ @typeName(@TypeOf(elem)));
        }
    }
    return @Type(.{
        .@"struct" = .{
            .is_tuple = true,
            .layout = .auto,
            .decls = &.{},
            .fields = tuple_fields,
        },
    });
}

/// Given .{Foo, Bar, Baz} Mach modules, returns .{.foo = Foo, .bar = Bar, .baz = Baz} with field
/// names corresponding to each module's `pub const mach_module = .foo;` name.
fn ModuleTypesByName(comptime modules: anytype) type {
    var fields: []const std.builtin.Type.StructField = &[0]std.builtin.Type.StructField{};
    for (modules) |M| {
        fields = fields ++ [_]std.builtin.Type.StructField{.{
            .name = @tagName(M.mach_module),
            .type = type,
            .default_value = &M,
            .is_comptime = true,
            .alignment = @alignOf(type),
        }};
    }
    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .is_tuple = false,
            .fields = fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

/// Given .{Foo, Bar, Baz} Mach modules, returns .{.foo: Foo = undefined, .bar: Bar = undefined, .baz: Baz = undefined}
/// with field names corresponding to each module's `pub const mach_module = .foo;` name, and each Foo type.
fn ModulesByName(comptime modules: anytype) type {
    var fields: []const std.builtin.Type.StructField = &[0]std.builtin.Type.StructField{};
    for (modules) |M| {
        fields = fields ++ [_]std.builtin.Type.StructField{.{
            .name = @tagName(M.mach_module),
            .type = M,
            .default_value = &@as(M, undefined),
            .is_comptime = false,
            .alignment = @alignOf(M),
        }};
    }
    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .is_tuple = false,
            .fields = fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}
