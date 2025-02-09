const std = @import("std");
const Ast = @import("Ast.zig");
const Air = @import("Air.zig");
const ErrorList = @import("ErrorList.zig");
const TokenTag = @import("Token.zig").Tag;
const Loc = @import("Token.zig").Loc;
const Inst = Air.Inst;
const InstIndex = Air.InstIndex;
const RefIndex = Air.RefIndex;
const StringIndex = Air.StringIndex;
const ValueIndex = Air.ValueIndex;
const Node = Ast.Node;
const NodeIndex = Ast.NodeIndex;
const TokenIndex = Ast.TokenIndex;
const stringToEnum = std.meta.stringToEnum;
const indexOf = std.mem.indexOfScalar;

const AstGen = @This();

allocator: std.mem.Allocator,
tree: *const Ast,
instructions: std.AutoArrayHashMapUnmanaged(Inst, void) = .{},
refs: std.ArrayListUnmanaged(InstIndex) = .{},
strings: std.ArrayListUnmanaged(u8) = .{},
values: std.ArrayListUnmanaged(u8) = .{},
scratch: std.ArrayListUnmanaged(InstIndex) = .{},
global_var_refs: std.AutoArrayHashMapUnmanaged(InstIndex, void) = .{},
globals: std.ArrayListUnmanaged(InstIndex) = .{},
has_array_length: bool = false,
compute_stage: InstIndex = .none,
vertex_stage: InstIndex = .none,
fragment_stage: InstIndex = .none,
entry_point_name: ?[]const u8 = null,
scope_pool: std.heap.MemoryPool(Scope),
current_fn_scope: *Scope = undefined,
inst_arena: std.heap.ArenaAllocator,
errors: *ErrorList,

pub const Scope = struct {
    tag: Tag,
    /// this is undefined if tag == .root
    parent: *Scope,
    decls: std.AutoHashMapUnmanaged(NodeIndex, error{AnalysisFail}!InstIndex) = .{},

    const Tag = union(enum) {
        root,
        @"fn": struct {
            stage: Inst.Fn.Stage,
            return_type: InstIndex,
            returned: bool,
            flattened_params: std.AutoHashMapUnmanaged(InstIndex, InstIndex),
        },
        block,
        loop,
        continuing,
        switch_case,
        @"if",
        @"for",
    };
};

pub fn genTranslationUnit(astgen: *AstGen) !RefIndex {
    var root_scope = try astgen.scope_pool.create();
    root_scope.* = .{ .tag = .root, .parent = undefined };

    const global_nodes = astgen.tree.spanToList(.globals);
    try astgen.scanDecls(root_scope, global_nodes);

    for (global_nodes) |node| {
        var global = root_scope.decls.get(node).? catch continue;
        global = switch (astgen.tree.nodeTag(node)) {
            .@"fn" => blk: {
                break :blk astgen.genFn(root_scope, node, false) catch |err| switch (err) {
                    error.Skiped => continue,
                    else => |e| e,
                };
            },
            else => continue,
        } catch |err| {
            if (err == error.AnalysisFail) {
                root_scope.decls.putAssumeCapacity(node, error.AnalysisFail);
                continue;
            }
            return err;
        };
        root_scope.decls.putAssumeCapacity(node, global);
        try astgen.globals.append(astgen.allocator, global);
    }

    if (astgen.errors.list.items.len > 0) return error.AnalysisFail;

    if (astgen.entry_point_name != null and
        astgen.compute_stage == .none and
        astgen.vertex_stage == .none and
        astgen.fragment_stage == .none)
    {
        try astgen.errors.add(Loc{ .start = 0, .end = 1 }, "entry point not found", .{}, null);
    }

    return astgen.addRefList(astgen.globals.items);
}

/// adds `nodes` to scope and checks for re-declarations
fn scanDecls(astgen: *AstGen, scope: *Scope, nodes: []const NodeIndex) !void {
    for (nodes) |decl_node| {
        const loc = astgen.tree.declNameLoc(decl_node) orelse continue;
        const name = loc.slice(astgen.tree.source);

        var iter = scope.decls.keyIterator();
        while (iter.next()) |node| {
            const name_loc = astgen.tree.declNameLoc(node.*).?;
            if (std.mem.eql(u8, name, name_loc.slice(astgen.tree.source))) {
                try astgen.errors.add(
                    loc,
                    "redeclaration of '{s}'",
                    .{name},
                    try astgen.errors.createNote(
                        name_loc,
                        "other declaration here",
                        .{},
                    ),
                );
                return error.AnalysisFail;
            }
        }

        try scope.decls.putNoClobber(astgen.scope_pool.arena.allocator(), decl_node, .none);
    }
}

fn genGlobalDecl(astgen: *AstGen, scope: *Scope, node: NodeIndex) error{ OutOfMemory, AnalysisFail }!InstIndex {
    const decl = switch (astgen.tree.nodeTag(node)) {
        .global_var => astgen.genGlobalVar(scope, node),
        .override => astgen.genOverride(scope, node),
        .@"const" => astgen.genConst(scope, node),
        .@"struct" => astgen.genStruct(scope, node),
        .@"fn" => astgen.genFn(scope, node, false),
        .type_alias => astgen.genTypeAlias(scope, node),
        else => unreachable,
    } catch |err| switch (err) {
        error.AnalysisFail => {
            scope.decls.putAssumeCapacity(node, error.AnalysisFail);
            return error.AnalysisFail;
        },
        error.Skiped => unreachable,
        else => |e| return e,
    };

    scope.decls.putAssumeCapacity(node, decl);
    try astgen.globals.append(astgen.allocator, decl);
    return decl;
}

fn genGlobalVar(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_rhs = astgen.tree.nodeRHS(node);
    const extra = astgen.tree.extraData(Node.GlobalVar, astgen.tree.nodeLHS(node));
    const name_loc = astgen.tree.declNameLoc(node).?;

    var is_resource = false;
    var var_type = InstIndex.none;
    if (extra.type != .none) {
        var_type = try astgen.genType(scope, extra.type);

        switch (astgen.getInst(var_type)) {
            .sampler_type,
            .comparison_sampler_type,
            .external_texture_type,
            .texture_type,
            => {
                is_resource = true;
            },
            else => {},
        }
    }

    var addr_space = Inst.PointerType.AddressSpace.uniform_constant;
    if (extra.addr_space != .none) {
        const addr_space_loc = astgen.tree.tokenLoc(extra.addr_space);
        const ast_addr_space = stringToEnum(Ast.AddressSpace, addr_space_loc.slice(astgen.tree.source)).?;
        addr_space = switch (ast_addr_space) {
            .function => .function,
            .private => .private,
            .workgroup => .workgroup,
            .uniform => .uniform,
            .storage => .storage,
        };
    }

    if (addr_space == .uniform or addr_space == .storage) {
        is_resource = true;
    }

    var access_mode = Inst.PointerType.AccessMode.read_write;
    if (extra.access_mode != .none) {
        const access_mode_loc = astgen.tree.tokenLoc(extra.access_mode);
        const ast_access_mode = stringToEnum(Ast.AccessMode, access_mode_loc.slice(astgen.tree.source)).?;
        access_mode = switch (ast_access_mode) {
            .read => .read,
            .write => .write,
            .read_write => .read_write,
        };
    }

    var binding = InstIndex.none;
    var group = InstIndex.none;
    if (extra.attrs != .none) {
        for (astgen.tree.spanToList(extra.attrs)) |attr| {
            if (!is_resource) {
                try astgen.errors.add(
                    astgen.tree.nodeLoc(attr),
                    "variable '{s}' is not a resource",
                    .{name_loc.slice(astgen.tree.source)},
                    null,
                );
                return error.AnalysisFail;
            }

            switch (astgen.tree.nodeTag(attr)) {
                .attr_binding => binding = try astgen.attrBinding(scope, attr),
                .attr_group => group = try astgen.attrGroup(scope, attr),
                else => {
                    try astgen.errors.add(
                        astgen.tree.nodeLoc(attr),
                        "unexpected attribute '{s}'",
                        .{astgen.tree.nodeLoc(attr).slice(astgen.tree.source)},
                        null,
                    );
                    return error.AnalysisFail;
                },
            }
        }
    }

    if (is_resource and (binding == .none or group == .none)) {
        try astgen.errors.add(
            astgen.tree.nodeLoc(node),
            "resource variable must specify binding and group",
            .{},
            null,
        );
        return error.AnalysisFail;
    }

    var init = InstIndex.none;
    if (node_rhs != .none) {
        init = try astgen.genExpr(scope, node_rhs);
    }

    const name = try astgen.addString(name_loc.slice(astgen.tree.source));
    return astgen.addInst(.{
        .@"var" = .{
            .name = name,
            .type = var_type,
            .addr_space = addr_space,
            .access_mode = access_mode,
            .binding = binding,
            .group = group,
            .init = init,
        },
    });
}

fn genOverride(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_rhs = astgen.tree.nodeRHS(node);
    const extra = astgen.tree.extraData(Node.Override, astgen.tree.nodeLHS(node));
    const name_loc = astgen.tree.declNameLoc(node).?;

    var override_type = InstIndex.none;
    if (extra.type != .none) {
        override_type = try astgen.genType(scope, extra.type);
    }

    var id = InstIndex.none;
    if (extra.attrs != .none) {
        for (astgen.tree.spanToList(extra.attrs)) |attr| {
            switch (astgen.tree.nodeTag(attr)) {
                .attr_id => id = try astgen.attrId(scope, attr),
                else => {
                    try astgen.errors.add(
                        astgen.tree.nodeLoc(attr),
                        "unexpected attribute '{s}'",
                        .{astgen.tree.nodeLoc(attr).slice(astgen.tree.source)},
                        null,
                    );
                    return error.AnalysisFail;
                },
            }
        }
    }

    var init = InstIndex.none;
    if (node_rhs != .none) {
        init = try astgen.genExpr(scope, node_rhs);
    }

    const name = try astgen.addString(name_loc.slice(astgen.tree.source));
    return astgen.addInst(.{
        .@"var" = .{
            .name = name,
            .type = override_type,
            .init = init,
            .addr_space = .private,
            .access_mode = .read,
            .id = id,
        },
    });
}

fn genStruct(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const name_str = astgen.tree.declNameLoc(node).?.slice(astgen.tree.source);
    const name = try astgen.addString(name_str);
    const members = try astgen.genStructMembers(scope, astgen.tree.nodeLHS(node));
    return astgen.addInst(.{
        .@"struct" = .{
            .name = name,
            .members = members,
        },
    });
}

fn genStructMembers(astgen: *AstGen, scope: *Scope, node: NodeIndex) !RefIndex {
    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.shrinkRetainingCapacity(scratch_top);

    const member_nodes_list = astgen.tree.spanToList(node);
    for (member_nodes_list, 0..) |member_node, i| {
        const member_name_loc = astgen.tree.tokenLoc(astgen.tree.nodeToken(member_node));
        const member_attrs_node = astgen.tree.nodeLHS(member_node);
        const member_type_node = astgen.tree.nodeRHS(member_node);
        const member_type_loc = astgen.tree.nodeLoc(member_type_node);
        const member_type = astgen.genType(scope, member_type_node) catch |err| switch (err) {
            error.AnalysisFail => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const member_type_inst = astgen.getInst(member_type);

        switch (member_type_inst) {
            .array,
            .atomic_type,
            .@"struct",
            => {},
            inline .bool, .int, .float, .vector, .matrix => |data| {
                std.debug.assert(data.value == null);
            },
            else => {
                try astgen.errors.add(
                    member_name_loc,
                    "invalid struct member type '{s}'",
                    .{member_type_loc.slice(astgen.tree.source)},
                    null,
                );
                return error.AnalysisFail;
            },
        }

        if (member_type_inst == .array) {
            const array_len = member_type_inst.array.len;
            if (array_len == .none and i + 1 != member_nodes_list.len) {
                try astgen.errors.add(
                    member_name_loc,
                    "struct member with runtime-sized array type, must be the last member of the structure",
                    .{},
                    null,
                );
                return error.AnalysisFail;
            }
        }

        var @"align": ?u29 = null;
        var size: ?u32 = null;
        var builtin: ?Inst.Builtin = null;
        var location: ?u16 = null;
        var interpolate: ?Inst.Interpolate = null;
        if (member_attrs_node != .none) {
            for (astgen.tree.spanToList(member_attrs_node)) |attr| {
                switch (astgen.tree.nodeTag(attr)) {
                    .attr_align => @"align" = try astgen.attrAlign(scope, attr),
                    .attr_size => size = try astgen.attrSize(scope, attr),
                    .attr_location => location = try astgen.attrLocation(scope, attr),
                    .attr_builtin => builtin = astgen.attrBuiltin(attr),
                    .attr_interpolate => interpolate = astgen.attrInterpolate(attr),
                    else => {
                        try astgen.errors.add(
                            astgen.tree.nodeLoc(attr),
                            "unexpected attribute '{s}'",
                            .{astgen.tree.nodeLoc(attr).slice(astgen.tree.source)},
                            null,
                        );
                        return error.AnalysisFail;
                    },
                }
            }
        }

        const name = try astgen.addString(member_name_loc.slice(astgen.tree.source));
        const member = try astgen.addInst(.{
            .struct_member = .{
                .name = name,
                .type = member_type,
                .index = @intCast(i),
                .@"align" = @"align",
                .size = size,
                .builtin = builtin,
                .location = location,
                .interpolate = interpolate,
            },
        });
        try astgen.scratch.append(astgen.allocator, member);
    }

    return astgen.addRefList(astgen.scratch.items[scratch_top..]);
}

fn genFn(astgen: *AstGen, root_scope: *Scope, node: NodeIndex, only_entry_point: bool) !InstIndex {
    const scratch_top = astgen.global_var_refs.count();
    defer astgen.global_var_refs.shrinkRetainingCapacity(scratch_top);

    astgen.has_array_length = false;

    const fn_proto = astgen.tree.extraData(Node.FnProto, astgen.tree.nodeLHS(node));
    const node_rhs = astgen.tree.nodeRHS(node);
    const node_loc = astgen.tree.nodeLoc(node);

    var return_type = InstIndex.none;
    var return_attrs = Inst.Fn.ReturnAttrs{
        .builtin = null,
        .location = null,
        .interpolate = null,
        .invariant = false,
    };
    if (fn_proto.return_type != .none) {
        return_type = try astgen.genType(root_scope, fn_proto.return_type);

        if (fn_proto.return_attrs != .none) {
            for (astgen.tree.spanToList(fn_proto.return_attrs)) |attr| {
                switch (astgen.tree.nodeTag(attr)) {
                    .attr_invariant => return_attrs.invariant = true,
                    .attr_location => return_attrs.location = try astgen.attrLocation(root_scope, attr),
                    .attr_builtin => return_attrs.builtin = astgen.attrBuiltin(attr),
                    .attr_interpolate => return_attrs.interpolate = astgen.attrInterpolate(attr),
                    else => {
                        try astgen.errors.add(
                            astgen.tree.nodeLoc(attr),
                            "unexpected attribute '{s}'",
                            .{astgen.tree.nodeLoc(attr).slice(astgen.tree.source)},
                            null,
                        );
                        return error.AnalysisFail;
                    },
                }
            }
        }
    }

    var stage: Inst.Fn.Stage = .none;
    var workgroup_size_attr = NodeIndex.none;
    var is_const = false;
    if (fn_proto.attrs != .none) {
        for (astgen.tree.spanToList(fn_proto.attrs)) |attr| {
            switch (astgen.tree.nodeTag(attr)) {
                .attr_vertex,
                .attr_fragment,
                .attr_compute,
                => |stage_attr| {
                    if (stage != .none) {
                        try astgen.errors.add(astgen.tree.nodeLoc(attr), "multiple shader stages", .{}, null);
                        return error.AnalysisFail;
                    }

                    stage = switch (stage_attr) {
                        .attr_vertex => .vertex,
                        .attr_fragment => .fragment,
                        .attr_compute => .{ .compute = undefined },
                        else => unreachable,
                    };
                },
                .attr_workgroup_size => workgroup_size_attr = attr,
                .attr_const => is_const = true,
                else => {
                    try astgen.errors.add(
                        astgen.tree.nodeLoc(attr),
                        "unexpected attribute '{s}'",
                        .{astgen.tree.nodeLoc(attr).slice(astgen.tree.source)},
                        null,
                    );
                    return error.AnalysisFail;
                },
            }
        }
    }

    if (only_entry_point and stage == .none) return error.Skiped;

    if (stage == .compute) {
        if (return_type != .none) {
            try astgen.errors.add(
                astgen.tree.nodeLoc(fn_proto.return_type),
                "return type on compute function",
                .{},
                null,
            );
            return error.AnalysisFail;
        }

        if (workgroup_size_attr == .none) {
            try astgen.errors.add(
                node_loc,
                "@workgroup_size not specified on compute shader",
                .{},
                null,
            );
            return error.AnalysisFail;
        }

        const workgroup_size_data = astgen.tree.extraData(Ast.Node.WorkgroupSize, astgen.tree.nodeLHS(workgroup_size_attr));
        stage.compute = Inst.Fn.Stage.WorkgroupSize{
            .x = try astgen.genExpr(root_scope, workgroup_size_data.x),
            .y = blk: {
                if (workgroup_size_data.y == .none) break :blk .none;
                break :blk try astgen.genExpr(root_scope, workgroup_size_data.y);
            },
            .z = blk: {
                if (workgroup_size_data.z == .none) break :blk .none;
                break :blk try astgen.genExpr(root_scope, workgroup_size_data.z);
            },
        };
    } else if (workgroup_size_attr != .none) {
        try astgen.errors.add(
            node_loc,
            "@workgroup_size must be specified with a compute shader",
            .{},
            null,
        );
        return error.AnalysisFail;
    }

    const scope = try astgen.scope_pool.create();
    scope.* = .{
        .tag = .{
            .@"fn" = .{
                .stage = stage,
                .return_type = return_type,
                .returned = false,
                .flattened_params = .{},
            },
        },
        .parent = root_scope,
    };
    astgen.current_fn_scope = scope;

    var params = RefIndex.none;
    if (fn_proto.params != .none) {
        params = try astgen.genFnParams(scope, fn_proto.params);
    }

    const name_slice = astgen.tree.declNameLoc(node).?.slice(astgen.tree.source);
    const name = try astgen.addString(name_slice);
    const block = try astgen.genBlock(scope, node_rhs);

    if (return_type != .none and !scope.tag.@"fn".returned) {
        try astgen.errors.add(node_loc, "function does not return", .{}, null);
        return error.AnalysisFail;
    }

    const global_var_refs = try astgen.addRefList(astgen.global_var_refs.keys()[scratch_top..]);

    const inst = try astgen.addInst(.{
        .@"fn" = .{
            .name = name,
            .stage = stage,
            .is_const = is_const,
            .params = params,
            .return_type = return_type,
            .return_attrs = return_attrs,
            .block = block,
            .global_var_refs = global_var_refs,
            .has_array_length = astgen.has_array_length,
        },
    });

    if (astgen.entry_point_name) |entry_point_name| {
        if (std.mem.eql(u8, name_slice, entry_point_name)) {
            astgen.compute_stage = .none;
            astgen.vertex_stage = .none;
            astgen.fragment_stage = .none;
            if (stage == .none) {
                try astgen.errors.add(node_loc, "function is not an entry point", .{}, null);
                return error.AnalysisFail;
            }
        }
    }

    // only one kind of entry point per file
    switch (stage) {
        .none => {},
        .compute => {
            if (astgen.compute_stage != .none) {
                try astgen.errors.add(node_loc, "multiple compute entry point found", .{}, null);
                return error.AnalysisFail;
            }
            astgen.compute_stage = inst;
        },
        .vertex => {
            if (astgen.vertex_stage != .none) {
                try astgen.errors.add(node_loc, "multiple vertex entry point found", .{}, null);
                return error.AnalysisFail;
            }
            astgen.vertex_stage = inst;
        },
        .fragment => {
            if (astgen.fragment_stage != .none) {
                try astgen.errors.add(node_loc, "multiple fragment entry point found", .{}, null);
                return error.AnalysisFail;
            }
            astgen.fragment_stage = inst;
        },
    }

    return inst;
}

fn genTypeAlias(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    return astgen.genType(scope, node_lhs);
}

fn genFnParams(astgen: *AstGen, scope: *Scope, node: NodeIndex) !RefIndex {
    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.shrinkRetainingCapacity(scratch_top);

    const param_nodes = astgen.tree.spanToList(node);
    try astgen.scanDecls(scope, param_nodes);

    for (param_nodes) |param_node| {
        const param_type_node = astgen.tree.nodeRHS(param_node);
        const param_type = try astgen.genType(scope, param_type_node);
        const param_name_loc = astgen.tree.tokenLoc(astgen.tree.nodeToken(param_node));
        const param_name = try astgen.addString(param_name_loc.slice(astgen.tree.source));

        if (scope.tag.@"fn".stage != .none and astgen.getInst(param_type) == .@"struct") {
            const members = astgen.refToList(astgen.getInst(param_type).@"struct".members);
            for (members) |member_inst| {
                const member = astgen.getInst(member_inst).struct_member;
                const param = try astgen.addInst(.{
                    .fn_param = .{
                        .name = member.name,
                        .type = member.type,
                        .builtin = member.builtin,
                        .interpolate = member.interpolate,
                        .location = member.location,
                        .invariant = false,
                    },
                });
                try astgen.current_fn_scope.tag.@"fn".flattened_params.put(
                    astgen.inst_arena.allocator(),
                    member_inst,
                    param,
                );
                try astgen.scratch.append(astgen.allocator, param);
            }

            // TODO
            const param = try astgen.addInst(.{
                .fn_param = .{
                    .name = param_name,
                    .type = param_type,
                    .builtin = null,
                    .interpolate = null,
                    .location = null,
                    .invariant = false,
                },
            });
            scope.decls.putAssumeCapacity(param_node, param);
        } else {
            var builtin: ?Inst.Builtin = null;
            var inter: ?Inst.Interpolate = null;
            var location: ?u16 = null;
            var invariant: bool = false;

            const param_attrs_node = astgen.tree.nodeLHS(param_node);
            if (param_attrs_node != .none) {
                for (astgen.tree.spanToList(param_attrs_node)) |attr| {
                    switch (astgen.tree.nodeTag(attr)) {
                        .attr_invariant => invariant = true,
                        .attr_location => location = try astgen.attrLocation(scope, attr),
                        .attr_builtin => builtin = astgen.attrBuiltin(attr),
                        .attr_interpolate => inter = astgen.attrInterpolate(attr),
                        else => {
                            try astgen.errors.add(
                                astgen.tree.nodeLoc(attr),
                                "unexpected attribute '{s}'",
                                .{astgen.tree.nodeLoc(attr).slice(astgen.tree.source)},
                                null,
                            );
                            return error.AnalysisFail;
                        },
                    }
                }
            }

            const param = try astgen.addInst(.{
                .fn_param = .{
                    .name = param_name,
                    .type = param_type,
                    .builtin = builtin,
                    .interpolate = inter,
                    .location = location,
                    .invariant = invariant,
                },
            });
            try astgen.scratch.append(astgen.allocator, param);
            scope.decls.putAssumeCapacity(param_node, param);
        }
    }

    return astgen.addRefList(astgen.scratch.items[scratch_top..]);
}

fn attrBinding(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);
    const binding = try astgen.genExpr(scope, node_lhs);

    const binding_res = try astgen.resolve(binding);
    if (astgen.getInst(binding_res) != .int) {
        try astgen.errors.add(
            node_lhs_loc,
            "binding value must be integer",
            .{},
            null,
        );
        return error.AnalysisFail;
    }

    if (astgen.getValue(Inst.Int.Value, astgen.getInst(binding_res).int.value.?).literal < 0) {
        try astgen.errors.add(
            node_lhs_loc,
            "binding value must be a positive",
            .{},
            null,
        );
        return error.AnalysisFail;
    }

    return binding;
}

fn attrId(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);
    const id = try astgen.genExpr(scope, node_lhs);

    const id_res = try astgen.resolve(id);
    if (astgen.getInst(id_res) != .int) {
        try astgen.errors.add(
            node_lhs_loc,
            "id value must be integer",
            .{},
            null,
        );
        return error.AnalysisFail;
    }

    if (astgen.getValue(Inst.Int.Value, astgen.getInst(id_res).int.value.?).literal < 0) {
        try astgen.errors.add(
            node_lhs_loc,
            "id value must be a positive",
            .{},
            null,
        );
        return error.AnalysisFail;
    }

    return id;
}

fn attrGroup(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);
    const group = try astgen.genExpr(scope, node_lhs);

    const inst = astgen.getInst(try astgen.resolve(group));
    if (inst != .int or inst.int.value == null) {
        try astgen.errors.add(
            node_lhs_loc,
            "group value must be a constant integer",
            .{},
            null,
        );
        return error.AnalysisFail;
    }

    if (astgen.getValue(Inst.Int.Value, inst.int.value.?).literal < 0) {
        try astgen.errors.add(
            node_lhs_loc,
            "group value must be a positive",
            .{},
            null,
        );
        return error.AnalysisFail;
    }

    return group;
}

fn attrAlign(astgen: *AstGen, scope: *Scope, node: NodeIndex) !u29 {
    const expr = try astgen.genExpr(scope, astgen.tree.nodeLHS(node));
    return @intCast(astgen.getValue(Air.Inst.Int.Value, astgen.getInst(expr).int.value.?).literal);
}

fn attrSize(astgen: *AstGen, scope: *Scope, node: NodeIndex) !u32 {
    const expr = try astgen.genExpr(scope, astgen.tree.nodeLHS(node));
    return @intCast(astgen.getValue(Air.Inst.Int.Value, astgen.getInst(expr).int.value.?).literal);
}

fn attrLocation(astgen: *AstGen, scope: *Scope, node: NodeIndex) !u16 {
    const inst_idx = try astgen.genExpr(scope, astgen.tree.nodeLHS(node));
    const value_idx = astgen.getInst(inst_idx).int.value.?;
    return @intCast(astgen.getValue(Inst.Int.Value, value_idx).literal);
}

fn attrBuiltin(astgen: *AstGen, node: NodeIndex) Inst.Builtin {
    const loc = astgen.tree.tokenLoc(astgen.tree.nodeLHS(node).asTokenIndex());
    return stringToEnum(Ast.Builtin, loc.slice(astgen.tree.source)).?;
}

fn attrInterpolate(astgen: *AstGen, node: NodeIndex) Inst.Interpolate {
    const inter_type_token = astgen.tree.nodeLHS(node).asTokenIndex();
    const inter_type_loc = astgen.tree.tokenLoc(inter_type_token);
    const inter_type_ast = stringToEnum(Ast.InterpolationType, inter_type_loc.slice(astgen.tree.source)).?;

    var inter = Inst.Interpolate{
        .type = switch (inter_type_ast) {
            .perspective => .perspective,
            .linear => .linear,
            .flat => .flat,
        },
        .sample = .none,
    };

    if (astgen.tree.nodeRHS(node) != .none) {
        const inter_sample_token = astgen.tree.nodeRHS(node).asTokenIndex();
        const inter_sample_loc = astgen.tree.tokenLoc(inter_sample_token);
        const inter_sample_ast = stringToEnum(Ast.InterpolationSample, inter_sample_loc.slice(astgen.tree.source)).?;
        inter.sample = switch (inter_sample_ast) {
            .center => .center,
            .centroid => .centroid,
            .sample => .sample,
        };
    }

    return inter;
}

fn genBlock(astgen: *AstGen, scope: *Scope, node: NodeIndex) error{ OutOfMemory, AnalysisFail }!InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) return .none;

    const stmnt_nodes = astgen.tree.spanToList(node_lhs);
    try astgen.scanDecls(scope, stmnt_nodes);

    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.shrinkRetainingCapacity(scratch_top);

    var is_unreachable = false;
    for (stmnt_nodes) |stmnt_node| {
        const stmnt_node_loc = astgen.tree.nodeLoc(stmnt_node);
        if (is_unreachable) {
            try astgen.errors.add(stmnt_node_loc, "unreachable code", .{}, null);
            return error.AnalysisFail;
        }
        const stmnt = try astgen.genStatement(scope, stmnt_node);
        if (astgen.getInst(stmnt) == .@"return") {
            is_unreachable = true;
        }
        try astgen.scratch.append(astgen.allocator, stmnt);
    }

    const statements = try astgen.addRefList(astgen.scratch.items[scratch_top..]);
    return astgen.addInst(.{ .block = statements });
}

fn genStatement(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    return switch (astgen.tree.nodeTag(node)) {
        .compound_assign => try astgen.genCompoundAssign(scope, node),
        .phony_assign => try astgen.genPhonyAssign(scope, node),
        .call => try astgen.genCall(scope, node),
        .@"return" => try astgen.genReturn(scope, node),
        .break_if => try astgen.genBreakIf(scope, node),
        .@"if" => try astgen.genIf(scope, node),
        .if_else => try astgen.genIfElse(scope, node),
        .if_else_if => try astgen.genIfElseIf(scope, node),
        .@"while" => try astgen.genWhile(scope, node),
        .@"for" => try astgen.genFor(scope, node),
        .@"switch" => try astgen.genSwitch(scope, node),
        .loop => try astgen.genLoop(scope, node),
        .block => blk: {
            const inner_scope = try astgen.scope_pool.create();
            inner_scope.* = .{ .tag = .block, .parent = scope };
            const inner_block = try astgen.genBlock(inner_scope, node);
            break :blk inner_block;
        },
        .continuing => try astgen.genContinuing(scope, node),
        .discard => try astgen.addInst(.discard),
        .@"break" => try astgen.addInst(.@"break"),
        .@"continue" => try astgen.addInst(.@"continue"),
        .increase => try astgen.genIncreaseDecrease(scope, node, .add),
        .decrease => try astgen.genIncreaseDecrease(scope, node, .sub),
        .@"var" => blk: {
            const decl = try astgen.genVar(scope, node);
            scope.decls.putAssumeCapacity(node, decl);
            break :blk decl;
        },
        .@"const" => blk: {
            const decl = try astgen.genConst(scope, node);
            scope.decls.putAssumeCapacity(node, decl);
            break :blk decl;
        },
        .let => blk: {
            const decl = try astgen.genLet(scope, node);
            scope.decls.putAssumeCapacity(node, decl);
            break :blk decl;
        },
        else => unreachable,
    };
}

fn genLoop(astgen: *AstGen, parent_scope: *Scope, node: NodeIndex) !InstIndex {
    const scope = try astgen.scope_pool.create();
    scope.* = .{ .tag = .loop, .parent = parent_scope };

    const block = try astgen.genBlock(scope, astgen.tree.nodeLHS(node));
    return astgen.addInst(.{ .loop = block });
}

fn genContinuing(astgen: *AstGen, parent_scope: *Scope, node: NodeIndex) !InstIndex {
    const scope = try astgen.scope_pool.create();
    scope.* = .{ .tag = .continuing, .parent = parent_scope };

    const block = try astgen.genBlock(scope, astgen.tree.nodeLHS(node));
    return astgen.addInst(.{ .continuing = block });
}

fn genBreakIf(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const expr = try astgen.genExpr(scope, astgen.tree.nodeLHS(node));
    return astgen.addInst(.{ .break_if = expr });
}

fn genIf(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);

    const cond = try astgen.genExpr(scope, node_lhs);
    const cond_res = try astgen.resolve(cond);
    if (astgen.getInst(cond_res) != .bool) {
        try astgen.errors.add(node_lhs_loc, "expected bool", .{}, null);
        return error.AnalysisFail;
    }

    const body_scope = try astgen.scope_pool.create();
    body_scope.* = .{ .tag = .@"if", .parent = scope };
    const block = try astgen.genBlock(body_scope, node_rhs);

    return astgen.addInst(.{
        .@"if" = .{
            .cond = cond,
            .body = block,
            .@"else" = .none,
        },
    });
}

fn genIfElse(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const if_node = astgen.tree.nodeLHS(node);
    const cond = try astgen.genExpr(scope, astgen.tree.nodeLHS(if_node));

    const if_body_scope = try astgen.scope_pool.create();
    if_body_scope.* = .{ .tag = .@"if", .parent = scope };
    const if_block = try astgen.genBlock(if_body_scope, astgen.tree.nodeRHS(if_node));

    const else_body_scope = try astgen.scope_pool.create();
    else_body_scope.* = .{ .tag = .@"if", .parent = scope };
    const else_block = try astgen.genBlock(else_body_scope, astgen.tree.nodeRHS(node));

    return astgen.addInst(.{
        .@"if" = .{
            .cond = cond,
            .body = if_block,
            .@"else" = else_block,
        },
    });
}

fn genIfElseIf(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const if_node = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const cond = try astgen.genExpr(scope, astgen.tree.nodeLHS(if_node));
    const block = try astgen.genBlock(scope, astgen.tree.nodeRHS(if_node));
    const else_if = switch (astgen.tree.nodeTag(node_rhs)) {
        .@"if" => try astgen.genIf(scope, node_rhs),
        .if_else => try astgen.genIfElse(scope, node_rhs),
        .if_else_if => try astgen.genIfElseIf(scope, node_rhs),
        else => unreachable,
    };
    return astgen.addInst(.{
        .@"if" = .{
            .cond = cond,
            .body = block,
            .@"else" = else_if,
        },
    });
}

fn genWhile(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);

    const cond = try astgen.genExpr(scope, node_lhs);
    const cond_res = try astgen.resolve(cond);
    if (astgen.getInst(cond_res) != .bool) {
        try astgen.errors.add(node_lhs_loc, "expected bool", .{}, null);
        return error.AnalysisFail;
    }

    const block = try astgen.genBlock(scope, node_rhs);
    return astgen.addInst(.{ .@"while" = .{ .cond = cond, .body = block } });
}

fn genFor(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const extra = astgen.tree.extraData(Ast.Node.ForHeader, node_lhs);

    var for_scope = try astgen.scope_pool.create();
    for_scope.* = .{ .tag = .@"for", .parent = scope };

    try astgen.scanDecls(for_scope, &.{extra.init});
    const init = switch (astgen.tree.nodeTag(extra.init)) {
        .@"var" => try astgen.genVar(for_scope, extra.init),
        .@"const" => try astgen.genConst(for_scope, extra.init),
        .let => try astgen.genLet(for_scope, extra.init),
        else => unreachable,
    };
    for_scope.decls.putAssumeCapacity(extra.init, init);

    const cond_node_loc = astgen.tree.nodeLoc(extra.cond);
    const cond = try astgen.genExpr(for_scope, extra.cond);
    const cond_res = try astgen.resolve(cond);
    if (astgen.getInst(cond_res) != .bool) {
        try astgen.errors.add(cond_node_loc, "expected bool", .{}, null);
        return error.AnalysisFail;
    }

    const update = switch (astgen.tree.nodeTag(extra.update)) {
        .phony_assign => try astgen.genPhonyAssign(for_scope, extra.update),
        .increase => try astgen.genIncreaseDecrease(for_scope, extra.update, .add),
        .decrease => try astgen.genIncreaseDecrease(for_scope, extra.update, .sub),
        .compound_assign => try astgen.genCompoundAssign(for_scope, extra.update),
        .call => try astgen.genCall(for_scope, extra.update),
        else => unreachable,
    };

    const block = try astgen.genBlock(for_scope, node_rhs);

    return astgen.addInst(.{
        .@"for" = .{
            .init = init,
            .cond = cond,
            .update = update,
            .body = block,
        },
    });
}

fn genSwitch(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const switch_on = try astgen.genExpr(scope, astgen.tree.nodeLHS(node));
    const switch_on_res = try astgen.resolve(switch_on);

    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.shrinkRetainingCapacity(scratch_top);

    const cases_nodes = astgen.tree.spanToList(astgen.tree.nodeRHS(node));
    for (cases_nodes) |cases_node| {
        const cases_node_tag = astgen.tree.nodeTag(cases_node);

        const cases_scope = try astgen.scope_pool.create();
        cases_scope.* = .{ .tag = .switch_case, .parent = scope };

        var cases = RefIndex.none;
        const body = try astgen.genBlock(cases_scope, astgen.tree.nodeRHS(cases_node));
        const default = cases_node_tag == .switch_default or cases_node_tag == .switch_case_default;

        switch (cases_node_tag) {
            .switch_case, .switch_case_default => {
                const cases_scratch_top = astgen.scratch.items.len;
                defer astgen.scratch.shrinkRetainingCapacity(cases_scratch_top);

                const case_nodes = astgen.tree.spanToList(astgen.tree.nodeLHS(cases_node));
                for (case_nodes) |case_node| {
                    const case_node_loc = astgen.tree.nodeLoc(case_node);
                    const case = try astgen.genExpr(scope, case_node);
                    const case_res = try astgen.resolve(case);
                    if (!try astgen.coerce(case_res, switch_on_res)) {
                        try astgen.errors.add(case_node_loc, "switch and case type mismatch", .{}, null);
                        return error.AnalysisFail;
                    }
                    try astgen.scratch.append(astgen.allocator, case);
                }

                cases = try astgen.addRefList(astgen.scratch.items[scratch_top..]);
            },
            .switch_default => {},
            else => unreachable,
        }

        const case_inst = try astgen.addInst(.{
            .switch_case = .{
                .cases = cases,
                .body = body,
                .default = default,
            },
        });
        try astgen.scratch.append(astgen.allocator, case_inst);
    }

    const cases_list = try astgen.addRefList(astgen.scratch.items[scratch_top..]);
    return astgen.addInst(.{
        .@"switch" = .{
            .switch_on = switch_on,
            .cases_list = cases_list,
        },
    });
}

fn genCompoundAssign(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const lhs = try astgen.genExpr(scope, node_lhs);
    const rhs = try astgen.genExpr(scope, node_rhs);
    const lhs_res = try astgen.resolve(lhs);
    const rhs_res = try astgen.resolve(rhs);

    if (!try astgen.isMutable(lhs)) {
        try astgen.errors.add(astgen.tree.nodeLoc(node), "cannot assign to constant", .{}, null);
        return error.AnalysisFail;
    }

    if (!try astgen.coerce(rhs_res, lhs_res)) {
        try astgen.errors.add(astgen.tree.nodeLoc(node), "type mismatch", .{}, null);
        return error.AnalysisFail;
    }

    const mod: Inst.Assign.Modifier = switch (astgen.tree.tokenTag(astgen.tree.nodeToken(node))) {
        .equal => .none,
        .plus_equal => .add,
        .minus_equal => .sub,
        .asterisk_equal => .mul,
        .slash_equal => .div,
        .percent_equal => .mod,
        .ampersand_equal => .@"and",
        .pipe_equal => .@"or",
        .xor_equal => .xor,
        .angle_bracket_angle_bracket_left_equal => .shl,
        .angle_bracket_angle_bracket_right_equal => .shr,
        else => unreachable,
    };

    return astgen.addInst(.{
        .assign = .{
            .mod = mod,
            .type = lhs_res,
            .lhs = lhs,
            .rhs = rhs,
        },
    });
}

pub fn isMutable(astgen: *AstGen, index: InstIndex) !bool {
    var idx = index;
    while (true) switch (astgen.getInst(idx)) {
        inline .field_access, .swizzle_access, .index_access => |access| idx = access.base,
        .unary => |un| switch (un.op) {
            .deref => return astgen.getInst(try astgen.resolve(un.expr)).ptr_type.access_mode != .read,
            else => unreachable,
        },
        .var_ref => |var_ref| idx = var_ref,
        .@"var" => |@"var"| return @"var".access_mode != .read,
        else => return false,
    };
}

fn genPhonyAssign(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    return astgen.genExpr(scope, node_lhs);
}

fn genIncreaseDecrease(astgen: *AstGen, scope: *Scope, node: NodeIndex, mod: Inst.Assign.Modifier) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);

    const lhs = try astgen.genExpr(scope, node_lhs);
    if (astgen.getInst(lhs) != .var_ref) {
        try astgen.errors.add(node_lhs_loc, "expected a reference", .{}, null);
        return error.AnalysisFail;
    }

    const lhs_res = try astgen.resolve(lhs);
    if (astgen.getInst(lhs_res) != .int) {
        try astgen.errors.add(node_lhs_loc, "expected an integer", .{}, null);
        return error.AnalysisFail;
    }

    const rhs = try astgen.addInst(.{ .int = .{
        .type = astgen.getInst(lhs_res).int.type,
        .value = try astgen.addValue(Inst.Int.Value, .{ .literal = 1 }),
    } });

    return astgen.addInst(.{ .assign = .{
        .mod = mod,
        .type = lhs_res,
        .lhs = lhs,
        .rhs = rhs,
    } });
}

fn genVar(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_rhs = astgen.tree.nodeRHS(node);
    const extra = astgen.tree.extraData(Node.Var, astgen.tree.nodeLHS(node));
    const name_loc = astgen.tree.declNameLoc(node).?;

    var is_resource = false; // TODO: research and remove this?
    var addr_space = Inst.PointerType.AddressSpace.function;
    if (extra.addr_space != .none) {
        const addr_space_loc = astgen.tree.tokenLoc(extra.addr_space);
        const ast_addr_space = stringToEnum(Ast.AddressSpace, addr_space_loc.slice(astgen.tree.source)).?;
        addr_space = switch (ast_addr_space) {
            .function => .function,
            .private => .private,
            .workgroup => .workgroup,
            .uniform => .uniform,
            .storage => .storage,
        };
    }

    if (addr_space == .uniform or addr_space == .storage) {
        is_resource = true;
    }

    var access_mode = Inst.PointerType.AccessMode.read_write;
    if (extra.access_mode != .none) {
        const access_mode_loc = astgen.tree.tokenLoc(extra.access_mode);
        const ast_access_mode = stringToEnum(Ast.AccessMode, access_mode_loc.slice(astgen.tree.source)).?;
        access_mode = switch (ast_access_mode) {
            .read => .read,
            .write => .write,
            .read_write => .read_write,
        };
    }

    var init = InstIndex.none;
    if (node_rhs != .none) {
        init = try astgen.genExpr(scope, node_rhs);
    }

    var var_type = InstIndex.none;
    if (extra.type != .none) {
        var_type = try astgen.genType(scope, extra.type);

        switch (astgen.getInst(var_type)) {
            .sampler_type,
            .comparison_sampler_type,
            .texture_type,
            .external_texture_type,
            => {
                is_resource = true;
            },
            else => {},
        }

        if (init != .none) {
            const init_res = try astgen.resolve(init);
            if (!try astgen.coerce(init_res, var_type)) {
                try astgen.errors.add(astgen.tree.nodeLoc(node_rhs), "type mismatch", .{}, null);
                return error.AnalysisFail;
            }
        }
    } else {
        var_type = try astgen.resolve(init);
    }

    const name = try astgen.addString(name_loc.slice(astgen.tree.source));
    return astgen.addInst(.{
        .@"var" = .{
            .name = name,
            .type = var_type,
            .addr_space = addr_space,
            .access_mode = access_mode,
            .init = init,
        },
    });
}

fn genConst(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const name_loc = astgen.tree.declNameLoc(node).?;
    const init = try astgen.genExpr(scope, node_rhs);
    var var_type = InstIndex.none;
    if (node_lhs != .none) {
        var_type = try astgen.genType(scope, node_lhs);
    } else {
        var_type = try astgen.resolve(init);
    }
    const name = try astgen.addString(name_loc.slice(astgen.tree.source));
    return astgen.addInst(.{
        .@"const" = .{
            .name = name,
            .type = var_type,
            .init = init,
        },
    });
}

fn genLet(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const name_loc = astgen.tree.declNameLoc(node).?;

    const init = try astgen.genExpr(scope, node_rhs);
    const name = try astgen.addString(name_loc.slice(astgen.tree.source));

    var var_type = InstIndex.none;
    if (node_lhs != .none) {
        var_type = try astgen.genType(scope, node_lhs);
    } else {
        var_type = try astgen.resolve(init);
    }

    return astgen.addInst(.{
        .@"var" = .{
            .name = name,
            .type = var_type,
            .init = init,
            .addr_space = .function,
            .access_mode = .read,
        },
    });
}

fn genExpr(astgen: *AstGen, scope: *Scope, node: NodeIndex) error{ OutOfMemory, AnalysisFail }!InstIndex {
    const node_tag = astgen.tree.nodeTag(node);
    return switch (node_tag) {
        .number => astgen.genNumber(node),
        .true => astgen.addInst(.{ .bool = .{ .value = .{ .literal = true } } }),
        .false => astgen.addInst(.{ .bool = .{ .value = .{ .literal = false } } }),
        .not => astgen.genNot(scope, node),
        .negate => astgen.genNegate(scope, node),
        .deref => astgen.genDeref(scope, node),
        .addr_of => astgen.genAddrOf(scope, node),
        .mul,
        .div,
        .mod,
        .add,
        .sub,
        .shl,
        .shr,
        .@"and",
        .@"or",
        .xor,
        .logical_and,
        .logical_or,
        .equal,
        .not_equal,
        .less_than,
        .less_than_equal,
        .greater_than,
        .greater_than_equal,
        => astgen.genBinary(scope, node),
        .index_access => astgen.genIndexAccess(scope, node),
        .field_access => astgen.genFieldAccess(scope, node),
        .call => astgen.genCall(scope, node),
        .bitcast => astgen.genBitcast(scope, node),
        .ident => astgen.genVarRef(scope, node),
        else => unreachable,
    };
}

fn genNumber(astgen: *AstGen, node: NodeIndex) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const bytes = node_loc.slice(astgen.tree.source);

    var i: usize = 0;
    var suffix: u8 = 0;
    var is_hex: bool = false;
    var has_exponent = false;
    var has_dot = false;

    if (bytes.len >= 2 and bytes[0] == '0') switch (bytes[1]) {
        '0'...'9' => {
            try astgen.errors.add(node_loc, "leading zero disallowed", .{}, null);
            return error.AnalysisFail;
        },
        'x', 'X' => {
            i = 2;
            is_hex = true;
        },
        else => {},
    };

    while (i < (bytes.len - 1)) : (i += 1) {
        const c = bytes[i];
        switch (c) {
            'e', 'E' => {
                if (is_hex) {
                    continue;
                }
                if (has_exponent) {
                    try astgen.errors.add(node_loc, "duplicate exponent '{c}'", .{c}, null);
                    return error.AnalysisFail;
                }
                has_exponent = true;
            },
            'p', 'P' => {
                if (!is_hex) {
                    try astgen.errors.add(node_loc, "hexadecimal exponent '{c}' in decimal float", .{c}, null);
                    return error.AnalysisFail;
                }
                // TODO
                try astgen.errors.add(node_loc, "hexadecimal float literals not implemented", .{}, null);
                return error.AnalysisFail;
            },
            '.' => has_dot = true,
            else => {},
        }
    }

    switch (bytes[bytes.len - 1]) {
        'i', 'u' => |c| {
            if (has_dot or has_exponent) {
                try astgen.errors.add(node_loc, "int suffix '{c}' on float literal", .{c}, null);
                return error.AnalysisFail;
            } else {
                suffix = c;
            }
        },
        'h' => |c| suffix = c,
        'f' => |c| {
            if (!is_hex or has_dot or has_exponent) {
                suffix = c;
            }
            // else is part of a hex literal
        },
        'e', 'E' => {
            if (!is_hex) {
                try astgen.errors.add(node_loc, "incomplete exponent", .{}, null);
                return error.AnalysisFail;
            } // else part of a hex literal
        },
        'p', 'P' => |c| {
            if (!is_hex) {
                try astgen.errors.add(node_loc, "hexadecimal exponent '{c}' in decimal float", .{c}, null);
                return error.AnalysisFail;
            }
            // TODO
            try astgen.errors.add(node_loc, "hexadecimal float literals not implemented", .{}, null);
            return error.AnalysisFail;
        },
        '.' => has_dot = true,
        else => {},
    }

    var inst: Inst = undefined;
    if (has_dot or has_exponent or suffix == 'f' or suffix == 'h') {
        if (is_hex) {
            // TODO
            try astgen.errors.add(node_loc, "hexadecimal float literals not implemented", .{}, null);
            return error.AnalysisFail;
        }

        const value = std.fmt.parseFloat(f32, bytes[0 .. bytes.len - @intFromBool(suffix != 0)]) catch |err| {
            try astgen.errors.add(
                node_loc,
                "cannot parse float literal ({s})",
                .{@errorName(err)},
                try astgen.errors.createNote(
                    null,
                    "this is a bug in sysgpu. please report it",
                    .{},
                ),
            );
            return error.AnalysisFail;
        };

        inst = .{
            .float = .{
                .type = switch (suffix) {
                    0, 'f' => .f32,
                    'h' => .f16,
                    else => unreachable,
                },
                .value = try astgen.addValue(Inst.Float.Value, .{ .literal = value }),
            },
        };
    } else {
        const value = std.fmt.parseInt(i33, bytes[0 .. bytes.len - @intFromBool(suffix != 0)], 0) catch |err| {
            try astgen.errors.add(
                node_loc,
                "cannot parse integer literal ({s})",
                .{@errorName(err)},
                try astgen.errors.createNote(
                    null,
                    "this is a bug in sysgpu. please report it",
                    .{},
                ),
            );
            return error.AnalysisFail;
        };

        inst = .{
            .int = .{
                .type = switch (suffix) {
                    0, 'i' => .i32,
                    'u' => .u32,
                    else => unreachable,
                },
                .value = try astgen.addValue(Inst.Int.Value, .{ .literal = value }),
            },
        };
    }
    return astgen.addInst(inst);
}

fn coerce(astgen: *AstGen, src: InstIndex, dst: InstIndex) !bool {
    if (astgen.eql(src, dst)) return true;

    const src_inst = astgen.getInst(src);
    const dst_inst = astgen.getInst(dst);

    switch (src_inst) {
        .int => |src_int| if (src_int.value != null) {
            const int_value = astgen.getValue(Air.Inst.Int.Value, src_inst.int.value.?);
            if (int_value == .literal) switch (dst_inst) {
                .int => |dst_int| {
                    if (src_int.type == .i32 and dst_int.type == .u32 and int_value.literal < 0) {
                        try astgen.errors.add(
                            Loc{ .start = 0, .end = 0 },
                            "TODO: undefined behavior: Op ({d}, rhs)",
                            .{int_value.literal},
                            null,
                        );
                        return error.AnalysisFail;
                    }

                    const value = try astgen.addValue(
                        Air.Inst.Int.Value,
                        Air.Inst.Int.Value{ .literal = @intCast(int_value.literal) },
                    );
                    astgen.instructions.keys()[@intFromEnum(src)] = .{
                        .int = .{
                            .type = dst_int.type,
                            .value = value,
                        },
                    };
                    return true;
                },
                .float => |dst_float| {
                    const value = try astgen.addValue(
                        Air.Inst.Float.Value,
                        Air.Inst.Float.Value{ .literal = @floatFromInt(int_value.literal) },
                    );
                    astgen.instructions.keys()[@intFromEnum(src)] = .{
                        .float = .{
                            .type = dst_float.type,
                            .value = value,
                        },
                    };
                    return true;
                },
                else => {},
            };
        },
        else => {},
    }

    return false;
}

fn genNot(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);
    const expr = try astgen.genExpr(scope, node_lhs);

    const expr_res = try astgen.resolve(expr);
    if (astgen.getInst(expr_res) == .bool) {
        return astgen.addInst(.{ .unary = .{ .op = .not, .result_type = expr_res, .expr = expr } });
    }

    try astgen.errors.add(
        node_lhs_loc,
        "cannot operate not (!) on '{s}'",
        .{node_lhs_loc.slice(astgen.tree.source)},
        null,
    );
    return error.AnalysisFail;
}

fn genNegate(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);
    const expr = try astgen.genExpr(scope, node_lhs);

    const expr_res = try astgen.resolve(expr);
    switch (astgen.getInst(expr_res)) {
        .int, .float => return astgen.addInst(.{
            .unary = .{
                .op = .negate,
                .result_type = expr_res,
                .expr = expr,
            },
        }),
        else => {},
    }

    try astgen.errors.add(
        node_lhs_loc,
        "cannot negate '{s}'",
        .{node_lhs_loc.slice(astgen.tree.source)},
        null,
    );
    return error.AnalysisFail;
}

fn genDeref(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);
    const expr = try astgen.genExpr(scope, node_lhs);
    const expr_res = try astgen.resolve(expr);
    const expr_res_inst = astgen.getInst(expr_res);

    if (expr_res_inst == .ptr_type) {
        return astgen.addInst(.{
            .unary = .{
                .op = .deref,
                .result_type = expr_res_inst.ptr_type.elem_type,
                .expr = expr,
            },
        });
    }

    try astgen.errors.add(
        node_lhs_loc,
        "cannot dereference '{s}'",
        .{node_lhs_loc.slice(astgen.tree.source)},
        null,
    );
    return error.AnalysisFail;
}

fn genAddrOf(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const expr = try astgen.genExpr(scope, astgen.tree.nodeLHS(node));
    const expr_res = try astgen.resolve(expr);
    const result_type = try astgen.addInst(.{
        .ptr_type = .{
            .elem_type = expr_res,
            .addr_space = .function, // TODO
            .access_mode = .read_write, // TODO
        },
    });

    const inst = try astgen.addInst(.{
        .unary = .{
            .op = .addr_of,
            .result_type = result_type,
            .expr = expr,
        },
    });
    return inst;
}

fn genBinary(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_tag = astgen.tree.nodeTag(node);
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const lhs = try astgen.genExpr(scope, node_lhs);
    const rhs = try astgen.genExpr(scope, node_rhs);

    const lhs_res = try astgen.resolve(lhs);
    const rhs_res = try astgen.resolve(rhs);
    const lhs_res_inst = astgen.getInst(lhs_res);
    const rhs_res_inst = astgen.getInst(rhs_res);

    var is_valid = false;
    var vector_size: ?Inst.Vector.Size = null;
    var arithmetic_res_type = InstIndex.none;

    switch (node_tag) {
        .shl, .shr, .@"and", .@"or", .xor => {
            is_valid = lhs_res_inst == .int and rhs_res_inst == .int;
        },
        .logical_and, .logical_or => {
            is_valid = lhs_res_inst == .bool and rhs_res_inst == .bool;
        },
        .mul,
        .div,
        .mod,
        .add,
        .sub,
        .equal,
        .not_equal,
        .less_than,
        .less_than_equal,
        .greater_than,
        .greater_than_equal,
        => switch (lhs_res_inst) {
            .int, .float => {
                if (try astgen.coerce(rhs_res, lhs_res) or try astgen.coerce(lhs_res, rhs_res)) {
                    is_valid = true;
                    arithmetic_res_type = lhs_res;
                }

                switch (rhs_res_inst) {
                    .vector => |v| {
                        if (try astgen.coerce(lhs_res, rhs_res_inst.vector.elem_type)) {
                            is_valid = true;
                            vector_size = v.size;
                            arithmetic_res_type = rhs_res;
                        }
                    },
                    else => {},
                }
            },
            .vector => |v| {
                vector_size = v.size;
                if (astgen.eql(rhs_res, lhs_res)) {
                    is_valid = true;
                    arithmetic_res_type = lhs_res;
                }

                if (try astgen.coerce(rhs_res, lhs_res_inst.vector.elem_type)) {
                    is_valid = true;
                    arithmetic_res_type = lhs_res;
                }

                if (rhs_res_inst == .matrix) {
                    if (astgen.getInst(lhs_res_inst.vector.elem_type) == .float) {
                        if (lhs_res_inst.vector.size == rhs_res_inst.matrix.cols) {
                            is_valid = true;
                            arithmetic_res_type = try astgen.addInst(.{ .vector = .{
                                .elem_type = lhs_res_inst.vector.elem_type,
                                .size = rhs_res_inst.matrix.rows,
                                .value = null,
                            } });
                        }

                        if (lhs_res_inst.vector.size == rhs_res_inst.matrix.rows) {
                            is_valid = true;
                            arithmetic_res_type = try astgen.addInst(.{ .vector = .{
                                .elem_type = lhs_res_inst.vector.elem_type,
                                .size = rhs_res_inst.matrix.cols,
                                .value = null,
                            } });
                        }
                    }
                }
            },
            .matrix => {
                if (rhs_res_inst == .matrix) {
                    if (astgen.eql(lhs_res_inst.matrix.elem_type, rhs_res_inst.matrix.elem_type)) {
                        // matCxR<T> matCxR<T>
                        if (lhs_res_inst.matrix.rows == rhs_res_inst.matrix.rows and
                            lhs_res_inst.matrix.cols == rhs_res_inst.matrix.cols)
                        {
                            is_valid = true;
                            arithmetic_res_type = lhs_res;
                        }

                        // matKxR<T> matCxK<T>
                        if (lhs_res_inst.matrix.cols == rhs_res_inst.matrix.rows) {
                            is_valid = true;
                            arithmetic_res_type = try astgen.addInst(.{ .matrix = .{
                                .elem_type = lhs_res_inst.matrix.elem_type,
                                .cols = rhs_res_inst.matrix.cols,
                                .rows = lhs_res_inst.matrix.rows,
                                .value = null,
                            } });
                        }

                        // matCxK<T> matKxR<T>
                        if (rhs_res_inst.matrix.cols == lhs_res_inst.matrix.rows) {
                            is_valid = true;
                            arithmetic_res_type = try astgen.addInst(.{ .matrix = .{
                                .elem_type = lhs_res_inst.matrix.elem_type,
                                .cols = lhs_res_inst.matrix.cols,
                                .rows = rhs_res_inst.matrix.rows,
                                .value = null,
                            } });
                        }
                    }
                }

                if (rhs_res_inst == .float) {
                    is_valid = true;
                    arithmetic_res_type = lhs_res;
                }

                if (rhs_res_inst == .vector) {
                    if (rhs_res_inst.vector.size == lhs_res_inst.matrix.cols) {
                        is_valid = true;
                        arithmetic_res_type = try astgen.addInst(.{ .vector = .{
                            .elem_type = rhs_res_inst.vector.elem_type,
                            .size = lhs_res_inst.matrix.rows,
                            .value = null,
                        } });
                    }

                    if (rhs_res_inst.vector.size == lhs_res_inst.matrix.rows) {
                        is_valid = true;
                        arithmetic_res_type = try astgen.addInst(.{ .vector = .{
                            .elem_type = rhs_res_inst.vector.elem_type,
                            .size = lhs_res_inst.matrix.cols,
                            .value = null,
                        } });
                    }
                }
            },
            else => {},
        },
        else => unreachable,
    }

    if (!is_valid) {
        try astgen.errors.add(
            node_loc,
            "invalid operation between {s} and {s}",
            .{ @tagName(lhs_res_inst), @tagName(rhs_res_inst) },
            null,
        );
        return error.AnalysisFail;
    }

    const op: Inst.Binary.Op = switch (node_tag) {
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .add => .add,
        .sub => .sub,
        .shl => .shl,
        .shr => .shr,
        .@"and" => .@"and",
        .@"or" => .@"or",
        .xor => .xor,
        .logical_and => .logical_and,
        .logical_or => .logical_or,
        .equal => .equal,
        .not_equal => .not_equal,
        .less_than => .less_than,
        .less_than_equal => .less_than_equal,
        .greater_than => .greater_than,
        .greater_than_equal => .greater_than_equal,
        else => unreachable,
    };

    const res_type = switch (op) {
        .mul,
        .div,
        .mod,
        .add,
        .sub,
        => arithmetic_res_type,
        .logical_and,
        .logical_or,
        .equal,
        .not_equal,
        .less_than,
        .less_than_equal,
        .greater_than,
        .greater_than_equal,
        => if (vector_size) |size|
            try astgen.addInst(.{ .vector = .{
                .elem_type = try astgen.addInst(.{ .bool = .{ .value = null } }),
                .size = size,
                .value = null,
            } })
        else
            try astgen.addInst(.{ .bool = .{ .value = null } }),
        else => lhs_res,
    };

    return astgen.addInst(.{ .binary = .{
        .op = op,
        .result_type = res_type,
        .lhs_type = lhs_res,
        .rhs_type = rhs_res,
        .lhs = lhs,
        .rhs = rhs,
    } });
}

fn genCall(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const token = astgen.tree.nodeToken(node);
    const token_tag = astgen.tree.tokenTag(token);
    const token_loc = astgen.tree.tokenLoc(token);
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const node_loc = astgen.tree.nodeLoc(node);

    if (node_rhs == .none) {
        std.debug.assert(token_tag == .ident);

        const builtin_fn = std.meta.stringToEnum(BuiltinFn, token_loc.slice(astgen.tree.source)) orelse {
            const decl = try astgen.findSymbol(scope, token);
            switch (astgen.getInst(decl)) {
                .@"fn" => return astgen.genFnCall(scope, node),
                .@"struct" => return astgen.genStructConstruct(scope, decl, node),
                else => {
                    try astgen.errors.add(
                        node_loc,
                        "'{s}' cannot be called",
                        .{token_loc.slice(astgen.tree.source)},
                        null,
                    );
                    return error.AnalysisFail;
                },
            }
        };
        switch (builtin_fn) {
            .all => return astgen.genBuiltinAllAny(scope, node, true),
            .any => return astgen.genBuiltinAllAny(scope, node, false),
            .select => return astgen.genBuiltinSelect(scope, node),
            .abs => return astgen.genGenericUnaryBuiltin(scope, node, .abs, &.{ .u32, .i32 }, &.{ .f32, .f16 }, false, false),
            .acos => return astgen.genGenericUnaryBuiltin(scope, node, .acos, &.{}, &.{ .f32, .f16 }, false, false),
            .acosh => return astgen.genGenericUnaryBuiltin(scope, node, .acosh, &.{}, &.{ .f32, .f16 }, false, false),
            .asin => return astgen.genGenericUnaryBuiltin(scope, node, .asin, &.{}, &.{ .f32, .f16 }, false, false),
            .asinh => return astgen.genGenericUnaryBuiltin(scope, node, .asinh, &.{}, &.{ .f32, .f16 }, false, false),
            .atan => return astgen.genGenericUnaryBuiltin(scope, node, .atan, &.{}, &.{ .f32, .f16 }, false, false),
            .atanh => return astgen.genGenericUnaryBuiltin(scope, node, .atanh, &.{}, &.{ .f32, .f16 }, false, false),
            .ceil => return astgen.genGenericUnaryBuiltin(scope, node, .ceil, &.{}, &.{ .f32, .f16 }, false, false),
            .cos => return astgen.genGenericUnaryBuiltin(scope, node, .cos, &.{}, &.{ .f32, .f16 }, false, false),
            .cosh => return astgen.genGenericUnaryBuiltin(scope, node, .cosh, &.{}, &.{ .f32, .f16 }, false, false),
            .countLeadingZeros => return astgen.genGenericUnaryBuiltin(scope, node, .count_leading_zeros, &.{ .u32, .i32 }, &.{}, false, false),
            .countOneBits => return astgen.genGenericUnaryBuiltin(scope, node, .count_one_bits, &.{ .u32, .i32 }, &.{}, false, false),
            .countTrailingZeros => return astgen.genGenericUnaryBuiltin(scope, node, .count_trailing_zeros, &.{ .u32, .i32 }, &.{}, false, false),
            .degrees => return astgen.genGenericUnaryBuiltin(scope, node, .degrees, &.{}, &.{ .f32, .f16 }, false, false),
            .exp => return astgen.genGenericUnaryBuiltin(scope, node, .exp, &.{}, &.{ .f32, .f16 }, false, false),
            .exp2 => return astgen.genGenericUnaryBuiltin(scope, node, .exp2, &.{}, &.{ .f32, .f16 }, false, false),
            .firstLeadingBit => return astgen.genGenericUnaryBuiltin(scope, node, .first_leading_bit, &.{ .u32, .i32 }, &.{}, false, false),
            .firstTrailingBit => return astgen.genGenericUnaryBuiltin(scope, node, .first_trailing_bit, &.{ .u32, .i32 }, &.{}, false, false),
            .floor => return astgen.genGenericUnaryBuiltin(scope, node, .floor, &.{}, &.{ .f32, .f16 }, false, false),
            .fract => return astgen.genGenericUnaryBuiltin(scope, node, .fract, &.{}, &.{ .f32, .f16 }, false, false),
            .inverseSqrt => return astgen.genGenericUnaryBuiltin(scope, node, .inverse_sqrt, &.{}, &.{ .f32, .f16 }, false, false),
            .length => return astgen.genGenericUnaryBuiltin(scope, node, .length, &.{}, &.{ .f32, .f16 }, false, true),
            .log => return astgen.genGenericUnaryBuiltin(scope, node, .log, &.{}, &.{ .f32, .f16 }, false, false),
            .log2 => return astgen.genGenericUnaryBuiltin(scope, node, .log2, &.{}, &.{ .f32, .f16 }, false, false),
            .quantizeToF16 => return astgen.genGenericUnaryBuiltin(scope, node, .quantize_to_F16, &.{}, &.{.f32}, false, false),
            .radians => return astgen.genGenericUnaryBuiltin(scope, node, .radians, &.{}, &.{ .f32, .f16 }, false, false),
            .reverseBits => return astgen.genGenericUnaryBuiltin(scope, node, .reverseBits, &.{ .u32, .i32 }, &.{}, false, false),
            .round => return astgen.genGenericUnaryBuiltin(scope, node, .round, &.{}, &.{ .f32, .f16 }, false, false),
            .saturate => return astgen.genGenericUnaryBuiltin(scope, node, .saturate, &.{}, &.{ .f32, .f16 }, false, false),
            .sign => return astgen.genGenericUnaryBuiltin(scope, node, .sign, &.{ .u32, .i32 }, &.{.f16}, false, false),
            .sin => return astgen.genGenericUnaryBuiltin(scope, node, .sin, &.{}, &.{ .f32, .f16 }, false, false),
            .sinh => return astgen.genGenericUnaryBuiltin(scope, node, .sinh, &.{}, &.{ .f32, .f16 }, false, false),
            .sqrt => return astgen.genGenericUnaryBuiltin(scope, node, .sqrt, &.{}, &.{ .f32, .f16 }, false, false),
            .tan => return astgen.genGenericUnaryBuiltin(scope, node, .tan, &.{}, &.{ .f32, .f16 }, false, false),
            .tanh => return astgen.genGenericUnaryBuiltin(scope, node, .tanh, &.{}, &.{ .f32, .f16 }, false, false),
            .trunc => return astgen.genGenericUnaryBuiltin(scope, node, .trunc, &.{}, &.{ .f32, .f16 }, false, false),
            .normalize => return astgen.genGenericUnaryBuiltin(scope, node, .normalize, &.{}, &.{ .f32, .f16 }, true, false),
            .min => return astgen.genGenericBinaryBuiltin(scope, node, .min, .any_in_any_out, true),
            .max => return astgen.genGenericBinaryBuiltin(scope, node, .max, .any_in_any_out, true),
            .atan2 => return astgen.genGenericBinaryBuiltin(scope, node, .atan2, .any_in_any_out, true),
            .distance => return astgen.genGenericBinaryBuiltin(scope, node, .distance, .any_in_scalar_out, false),
            .dot => return astgen.genGenericBinaryBuiltin(scope, node, .dot, .vector_in_scalar_out, false),
            .pow => return astgen.genGenericBinaryBuiltin(scope, node, .pow, .any_in_any_out, false),
            .step => return astgen.genGenericBinaryBuiltin(scope, node, .step, .any_in_any_out, false),
            .smoothstep => return astgen.genGenericFloatTripleBuiltin(scope, node, .smoothstep, false),
            .clamp => return astgen.genGenericFloatTripleBuiltin(scope, node, .clamp, false),
            .mix => return astgen.genGenericFloatTripleBuiltin(scope, node, .mix, true),
            .dpdx => return astgen.genDerivativeBuiltin(scope, node, .dpdx),
            .dpdxCoarse => return astgen.genDerivativeBuiltin(scope, node, .dpdx_coarse),
            .dpdxFine => return astgen.genDerivativeBuiltin(scope, node, .dpdx_fine),
            .dpdy => return astgen.genDerivativeBuiltin(scope, node, .dpdy),
            .dpdyCoarse => return astgen.genDerivativeBuiltin(scope, node, .dpdy_coarse),
            .dpdyFine => return astgen.genDerivativeBuiltin(scope, node, .dpdy_fine),
            .fwidth => return astgen.genDerivativeBuiltin(scope, node, .fwidth),
            .fwidthCoarse => return astgen.genDerivativeBuiltin(scope, node, .fwidth_coarse),
            .fwidthFine => return astgen.genDerivativeBuiltin(scope, node, .fwidth_fine),
            .arrayLength => return astgen.genArrayLengthBuiltin(scope, node),
            .textureSample => return astgen.genTextureSampleBuiltin(scope, node),
            .textureSampleLevel => return astgen.genTextureSampleLevelBuiltin(scope, node),
            .textureSampleGrad => return astgen.genTextureSampleGradBuiltin(scope, node),
            .textureDimensions => return astgen.genTextureDimensionsBuiltin(scope, node),
            .textureLoad => return astgen.genTextureLoadBuiltin(scope, node),
            .textureStore => return astgen.genTextureStoreBuiltin(scope, node),
            .workgroupBarrier => return astgen.genSimpleBuiltin(.workgroup_barrier),
            .storageBarrier => return astgen.genSimpleBuiltin(.storage_barrier),
            else => {
                try astgen.errors.add(
                    node_loc,
                    "TODO: unimplemented builtin '{s}'",
                    .{token_loc.slice(astgen.tree.source)},
                    null,
                );
                return error.AnalysisFail;
            },
        }
    }

    switch (token_tag) {
        .k_bool => {
            if (node_lhs == .none) {
                return astgen.addInst(.{ .bool = .{ .value = .{ .literal = false } } });
            }

            const arg_node = astgen.tree.spanToList(node_lhs)[0];
            const expr = try astgen.genExpr(scope, arg_node);
            const expr_res = try astgen.resolve(expr);
            switch (astgen.getInst(expr_res)) {
                .bool => return expr,
                .int, .float => return astgen.addInst(.{ .bool = .{
                    .value = .{
                        .cast = .{
                            .value = expr,
                            .type = expr_res,
                        },
                    },
                } }),
                else => {},
            }

            try astgen.errors.add(node_loc, "cannot construct bool", .{}, null);
            return error.AnalysisFail;
        },
        .k_u32, .k_i32 => {
            const ty: Inst.Int.Type = switch (token_tag) {
                .k_u32 => .u32,
                .k_i32 => .i32,
                else => unreachable,
            };

            if (node_lhs == .none) {
                const zero_value = try astgen.addValue(Inst.Int.Value, .{ .literal = 0 });
                return astgen.addInst(.{ .int = .{ .value = zero_value, .type = ty } });
            }

            const arg_nodes = astgen.tree.spanToList(node_lhs);
            if (arg_nodes.len > 1) {
                try astgen.errors.add(node_loc, "too many arguments", .{}, null);
                return error.AnalysisFail;
            }

            const arg_node = arg_nodes[0];
            const expr = try astgen.genExpr(scope, arg_node);
            const expr_res = try astgen.resolve(expr);

            switch (astgen.getInst(expr_res)) {
                .bool, .float => {},
                .int => |int| if (int.type == ty) return expr,
                else => {
                    try astgen.errors.add(node_loc, "type mismatch", .{}, null);
                    return error.AnalysisFail;
                },
            }

            const value = try astgen.addValue(Inst.Int.Value, .{
                .cast = .{
                    .value = expr,
                    .type = expr_res,
                },
            });

            return astgen.addInst(.{ .int = .{ .value = value, .type = ty } });
        },
        .k_f32, .k_f16 => {
            const ty: Inst.Float.Type = switch (token_tag) {
                .k_f32 => .f32,
                .k_f16 => .f16,
                else => unreachable,
            };

            if (node_lhs == .none) {
                const zero_value = try astgen.addValue(Inst.Float.Value, .{ .literal = 0 });
                return astgen.addInst(.{ .float = .{ .value = zero_value, .type = ty } });
            }

            const arg_nodes = astgen.tree.spanToList(node_lhs);
            if (arg_nodes.len > 1) {
                try astgen.errors.add(node_loc, "too many arguments", .{}, null);
                return error.AnalysisFail;
            }

            const arg_node = arg_nodes[0];
            const expr = try astgen.genExpr(scope, arg_node);
            const expr_res = try astgen.resolve(expr);

            switch (astgen.getInst(expr_res)) {
                .bool, .int => {},
                .float => |float| if (float.type == ty) return expr,
                else => {
                    try astgen.errors.add(node_loc, "type mismatch", .{}, null);
                    return error.AnalysisFail;
                },
            }

            const value = try astgen.addValue(Inst.Float.Value, .{
                .cast = .{
                    .value = expr,
                    .type = expr_res,
                },
            });

            return astgen.addInst(.{ .float = .{ .value = value, .type = ty } });
        },
        .k_vec2, .k_vec3, .k_vec4 => {
            const elem_type_node = astgen.tree.nodeLHS(node_rhs);
            const size: Inst.Vector.Size = switch (token_tag) {
                .k_vec2 => .two,
                .k_vec3 => .three,
                .k_vec4 => .four,
                else => unreachable,
            };
            var elem_type = InstIndex.none;

            if (elem_type_node != .none) {
                elem_type = try astgen.genType(scope, elem_type_node);
                switch (astgen.getInst(elem_type)) {
                    .bool, .int, .float => {},
                    else => {
                        try astgen.errors.add(
                            astgen.tree.nodeLoc(elem_type_node),
                            "invalid vector component type",
                            .{},
                            try astgen.errors.createNote(
                                null,
                                "must be 'i32', 'u32', 'f32', 'f16' or 'bool'",
                                .{},
                            ),
                        );
                        return error.AnalysisFail;
                    },
                }
            }

            if (node_lhs == .none) {
                if (elem_type_node == .none) {
                    try astgen.errors.add(node_loc, "cannot infer vector type", .{}, null);
                    return error.AnalysisFail;
                }

                return astgen.addInst(.{
                    .vector = .{
                        .elem_type = elem_type,
                        .size = size,
                        .value = .none,
                    },
                });
            }

            const arg_nodes = astgen.tree.spanToList(node_lhs);
            var args: [4]InstIndex = undefined;
            var cast = InstIndex.none;

            var capacity = @intFromEnum(size);
            for (arg_nodes) |arg_node| {
                const i = @intFromEnum(size) - capacity;
                const arg = try astgen.genExpr(scope, arg_node);
                const arg_loc = astgen.tree.nodeLoc(arg_node);
                const arg_res = try astgen.resolve(arg);

                if (capacity == 0) {
                    try astgen.errors.add(arg_loc, "doesn't fit in this vector", .{}, null);
                    return error.AnalysisFail;
                }

                switch (astgen.getInst(arg_res)) {
                    .vector => |arg_vec| {
                        if (elem_type == .none) {
                            elem_type = arg_vec.elem_type;
                        } else if (!astgen.eql(arg_vec.elem_type, elem_type)) {
                            cast = arg_vec.elem_type;
                        }

                        if (capacity >= @intFromEnum(arg_vec.size)) {
                            for (0..@intFromEnum(arg_vec.size)) |component_i| {
                                args[i + component_i] =
                                    astgen.resolveVectorValue(arg, @intCast(component_i)) orelse
                                    try astgen.addInst(.{
                                    .swizzle_access = .{
                                        .base = arg,
                                        .type = astgen.getInst(arg_res).vector.elem_type,
                                        .size = .one,
                                        .pattern = [_]Inst.SwizzleAccess.Component{
                                            @enumFromInt(component_i),
                                            undefined,
                                            undefined,
                                            undefined,
                                        },
                                    },
                                });
                            }
                            capacity -= @intFromEnum(arg_vec.size);
                        } else {
                            try astgen.errors.add(arg_loc, "doesn't fit in this vector", .{}, null);
                            return error.AnalysisFail;
                        }
                    },
                    .bool, .int, .float => {
                        var cast_arg = false;
                        if (elem_type == .none) {
                            elem_type = arg_res;
                        } else if (!astgen.eql(arg_res, elem_type)) {
                            cast_arg = true;
                        }

                        if (cast_arg) {
                            switch (astgen.getInst(elem_type)) {
                                .int => |int| {
                                    const arg_val = try astgen.addValue(
                                        Inst.Int.Value,
                                        .{ .cast = .{ .type = arg_res, .value = arg } },
                                    );
                                    args[i] = try astgen.addInst(.{ .int = .{
                                        .type = int.type,
                                        .value = arg_val,
                                    } });
                                },
                                .float => |float| {
                                    const arg_val = try astgen.addValue(
                                        Inst.Float.Value,
                                        .{ .cast = .{ .type = arg_res, .value = arg } },
                                    );
                                    args[i] = try astgen.addInst(.{ .float = .{
                                        .type = float.type,
                                        .value = arg_val,
                                    } });
                                },
                                .bool => {
                                    args[i] = try astgen.addInst(.{ .bool = .{
                                        .value = .{ .cast = .{ .type = arg_res, .value = arg } },
                                    } });
                                },
                                else => unreachable,
                            }
                        } else {
                            args[i] = arg;
                        }

                        if (arg_nodes.len == 1) {
                            @memset(args[i + 1 .. @intFromEnum(size)], args[i]);
                            capacity = 1;
                        }

                        capacity -= 1;
                    },
                    else => {
                        try astgen.errors.add(arg_loc, "type mismatch", .{}, null);
                        return error.AnalysisFail;
                    },
                }
            }

            if (capacity != 0) {
                try astgen.errors.add(node_loc, "arguments doesn't satisfy vector capacity", .{}, null);
                return error.AnalysisFail;
            }

            const value = try astgen.addValue(
                Inst.Vector.Value,
                if (cast == .none)
                    .{ .literal = args }
                else
                    .{ .cast = .{ .type = cast, .value = args } },
            );

            return astgen.addInst(.{
                .vector = .{
                    .elem_type = elem_type,
                    .size = size,
                    .value = value,
                },
            });
        },
        .k_mat2x2,
        .k_mat2x3,
        .k_mat2x4,
        .k_mat3x2,
        .k_mat3x3,
        .k_mat3x4,
        .k_mat4x2,
        .k_mat4x3,
        .k_mat4x4,
        => {
            const elem_type_node = astgen.tree.nodeLHS(node_rhs);
            const cols = matrixCols(token_tag);
            const rows = matrixRows(token_tag);
            var elem_type = InstIndex.none;

            if (elem_type_node != .none) {
                elem_type = try astgen.genType(scope, elem_type_node);
                if (astgen.getInst(elem_type) != .float) {
                    try astgen.errors.add(
                        astgen.tree.nodeLoc(elem_type_node),
                        "invalid matrix component type",
                        .{},
                        try astgen.errors.createNote(null, "must be 'f32', 'f16'", .{}),
                    );
                    return error.AnalysisFail;
                }
            }

            if (node_lhs == .none) {
                if (elem_type_node == .none) {
                    try astgen.errors.add(node_loc, "cannot infer matrix type", .{}, null);
                    return error.AnalysisFail;
                }

                return astgen.addInst(.{
                    .matrix = .{
                        .elem_type = elem_type,
                        .rows = rows,
                        .cols = cols,
                        .value = .none,
                    },
                });
            }

            const arg_nodes = astgen.tree.spanToList(node_lhs);
            var args: [4]InstIndex = undefined;

            var capacity = @intFromEnum(cols);
            for (arg_nodes) |arg_node| {
                const i = @intFromEnum(cols) - capacity;
                const arg = try astgen.genExpr(scope, arg_node);
                const arg_loc = astgen.tree.nodeLoc(arg_node);
                const arg_res = try astgen.resolve(arg);

                if (capacity == 0) {
                    try astgen.errors.add(arg_loc, "doesn't fit in this matrix", .{}, null);
                    return error.AnalysisFail;
                }

                switch (astgen.getInst(arg_res)) {
                    .matrix => |arg_mat| {
                        if (elem_type == .none) {
                            elem_type = arg_mat.elem_type;
                        } else {
                            if (!try astgen.coerce(arg_mat.elem_type, elem_type)) {
                                try astgen.errors.add(arg_loc, "type mismatch", .{}, null);
                                return error.AnalysisFail;
                            }
                        }

                        if (arg_nodes.len == 1 and arg_mat.cols == cols and arg_mat.rows == rows) {
                            return arg;
                        }

                        try astgen.errors.add(arg_loc, "invalid argument", .{}, null);
                        return error.AnalysisFail;
                    },
                    .vector => |arg_vec| {
                        if (elem_type == .none) {
                            elem_type = arg_vec.elem_type;
                        } else {
                            if (!try astgen.coerce(arg_vec.elem_type, elem_type)) {
                                try astgen.errors.add(arg_loc, "type mismatch", .{}, null);
                                return error.AnalysisFail;
                            }
                        }

                        if (@intFromEnum(arg_vec.size) != @intFromEnum(rows)) {
                            try astgen.errors.add(arg_loc, "invalid argument", .{}, null);
                            return error.AnalysisFail;
                        }

                        args[i] = arg;
                        capacity -= 1;
                    },
                    .float => {
                        if (elem_type == .none) {
                            elem_type = arg_res;
                        }

                        if (arg_nodes.len != 1) {
                            try astgen.errors.add(arg_loc, "invalid argument", .{}, null);
                            return error.AnalysisFail;
                        }

                        for (args[0..@intFromEnum(cols)]) |*arg_col| {
                            var arg_vec_value: [4]InstIndex = undefined;
                            @memset(arg_vec_value[0..@intFromEnum(rows)], arg);

                            const arg_vec = try astgen.addInst(.{
                                .vector = .{
                                    .elem_type = elem_type,
                                    .size = rows,
                                    .value = try astgen.addValue(Inst.Vector.Value, .{ .literal = arg_vec_value }),
                                },
                            });

                            arg_col.* = arg_vec;
                            capacity -= 1;
                        }
                    },
                    else => {
                        try astgen.errors.add(arg_loc, "type mismatch", .{}, null);
                        return error.AnalysisFail;
                    },
                }
            }

            if (capacity != 0) {
                try astgen.errors.add(node_loc, "arguments doesn't satisfy matrix capacity", .{}, null);
                return error.AnalysisFail;
            }

            return astgen.addInst(.{
                .matrix = .{
                    .elem_type = elem_type,
                    .cols = cols,
                    .rows = rows,
                    .value = try astgen.addValue(Inst.Matrix.Value, args),
                },
            });
        },
        .k_array => {
            if (node_lhs == .none) {
                return astgen.genArray(scope, node_rhs, .none);
            }

            const scratch_top = astgen.scratch.items.len;
            defer astgen.scratch.shrinkRetainingCapacity(scratch_top);

            var arg1_res = InstIndex.none;
            const arg_nodes = astgen.tree.spanToList(node_lhs);
            for (arg_nodes, 0..) |arg_node, i| {
                const arg = try astgen.genExpr(scope, arg_node);
                const arg_res = try astgen.resolve(arg);
                if (i == 0) {
                    arg1_res = arg_res;
                } else if (!try astgen.coerce(arg_res, arg1_res)) {
                    try astgen.errors.add(node_loc, "cannot construct array", .{}, null);
                    return error.AnalysisFail;
                }
                try astgen.scratch.append(astgen.allocator, arg);
            }

            const args = try astgen.addRefList(astgen.scratch.items[scratch_top..]);
            return astgen.genArray(scope, node_rhs, args);
        },
        else => unreachable,
    }
}

fn resolveVectorValue(astgen: *AstGen, vector_idx: InstIndex, value_idx: u3) ?InstIndex {
    return switch (astgen.getInst(vector_idx)) {
        .vector => |vector| switch (astgen.getValue(Inst.Vector.Value, vector.value.?)) {
            .literal => |literal| literal[value_idx],
            .cast => |cast| cast.value[value_idx],
        },
        inline .swizzle_access, .index_access => |access| astgen.resolveVectorValue(access.base, value_idx),
        else => null,
    };
}

fn genReturn(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_loc = astgen.tree.nodeLoc(node);

    var fn_scope = findFnScope(scope);
    var value = InstIndex.none;
    if (node_lhs != .none) {
        if (fn_scope.tag.@"fn".return_type == .none) {
            try astgen.errors.add(node_loc, "cannot return value", .{}, null);
            return error.AnalysisFail;
        }

        value = try astgen.genExpr(scope, node_lhs);
        const value_res = try astgen.resolve(value);
        if (!try astgen.coerce(value_res, fn_scope.tag.@"fn".return_type)) {
            try astgen.errors.add(node_loc, "return type mismatch", .{}, null);
            return error.AnalysisFail;
        }
    } else {
        if (fn_scope.tag.@"fn".return_type != .none) {
            try astgen.errors.add(node_loc, "return value not specified", .{}, null);
            return error.AnalysisFail;
        }
    }

    fn_scope.tag.@"fn".returned = true;
    return astgen.addInst(.{ .@"return" = value });
}

fn findFnScope(scope: *Scope) *Scope {
    var s = scope;
    while (true) {
        switch (s.tag) {
            .root => unreachable,
            .@"fn" => return s,
            .block,
            .loop,
            .continuing,
            .switch_case,
            .@"if",
            .@"for",
            => s = s.parent,
        }
    }
}

fn genFnCall(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_loc = astgen.tree.nodeLoc(node);
    const token = astgen.tree.nodeToken(node);
    const decl = try astgen.findSymbol(scope, token);
    if (astgen.tree.nodeRHS(node) != .none) {
        try astgen.errors.add(node_loc, "expected a function", .{}, null);
        return error.AnalysisFail;
    }

    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.shrinkRetainingCapacity(scratch_top);

    var args = RefIndex.none;
    if (node_lhs != .none) {
        const params = astgen.refToList(astgen.getInst(decl).@"fn".params);
        const arg_nodes = astgen.tree.spanToList(node_lhs);
        if (params.len != arg_nodes.len) {
            try astgen.errors.add(node_loc, "function params count mismatch", .{}, null);
            return error.AnalysisFail;
        }
        for (arg_nodes, 0..) |arg_node, i| {
            const arg = try astgen.genExpr(scope, arg_node);
            const arg_res = try astgen.resolve(arg);
            if (try astgen.coerce(astgen.getInst(params[i]).fn_param.type, arg_res)) {
                try astgen.scratch.append(astgen.allocator, arg);
            } else {
                try astgen.errors.add(
                    astgen.tree.nodeLoc(arg_node),
                    "value and member type mismatch",
                    .{},
                    null,
                );
                return error.AnalysisFail;
            }
        }
        args = try astgen.addRefList(astgen.scratch.items[scratch_top..]);
    } else {
        if (astgen.getInst(decl).@"fn".params != .none) {
            try astgen.errors.add(node_loc, "function params count mismatch", .{}, null);
            return error.AnalysisFail;
        }
    }

    for (astgen.refToList(astgen.getInst(decl).@"fn".global_var_refs)) |var_inst_idx| {
        try astgen.global_var_refs.put(astgen.allocator, var_inst_idx, {});
    }

    return astgen.addInst(.{ .call = .{ .@"fn" = decl, .args = args } });
}

fn genStructConstruct(astgen: *AstGen, scope: *Scope, decl: InstIndex, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_loc = astgen.tree.nodeLoc(node);

    const scratch_top = astgen.scratch.items.len;
    defer astgen.scratch.shrinkRetainingCapacity(scratch_top);

    const struct_members = astgen.refToList(astgen.getInst(decl).@"struct".members);
    if (node_lhs != .none) {
        const arg_nodes = astgen.tree.spanToList(node_lhs);
        if (struct_members.len != arg_nodes.len) {
            try astgen.errors.add(node_loc, "struct members count mismatch", .{}, null);
            return error.AnalysisFail;
        }
        for (arg_nodes, 0..) |arg_node, i| {
            const arg = try astgen.genExpr(scope, arg_node);
            const arg_res = try astgen.resolve(arg);
            if (try astgen.coerce(arg_res, astgen.getInst(struct_members[i]).struct_member.type)) {
                try astgen.scratch.append(astgen.allocator, arg);
            } else {
                try astgen.errors.add(
                    astgen.tree.nodeLoc(arg_node),
                    "value and member type mismatch",
                    .{},
                    null,
                );
                return error.AnalysisFail;
            }
        }
    } else {
        if (struct_members.len != 0) {
            try astgen.errors.add(node_loc, "struct members count mismatch", .{}, null);
            return error.AnalysisFail;
        }
    }

    const members = try astgen.addRefList(astgen.scratch.items[scratch_top..]);
    return astgen.addInst(.{
        .struct_construct = .{
            .@"struct" = decl,
            .members = members,
        },
    });
}

fn genBitcast(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const node_rhs = astgen.tree.nodeRHS(node);
    const node_lhs_loc = astgen.tree.nodeLoc(node_lhs);
    const node_rhs_loc = astgen.tree.nodeLoc(node_rhs);
    const lhs = try astgen.genType(scope, node_lhs);
    const lhs_inst = astgen.getInst(lhs);
    const rhs = try astgen.genExpr(scope, node_rhs);
    const rhs_res = try astgen.resolve(rhs);
    const rhs_res_inst = astgen.getInst(rhs_res);
    var result_type = InstIndex.none;

    const lhs_is_32bit = switch (lhs_inst) {
        .int => |int| int.type == .u32 or int.type == .i32,
        .float => |float| float.type == .f32,
        else => false,
    };
    const rhs_is_32bit = switch (rhs_res_inst) {
        .int => |int| int.type == .u32 or int.type == .i32,
        .float => |float| float.type == .f32,
        else => false,
    };

    if (lhs_is_32bit) {
        if (rhs_is_32bit) {
            // bitcast<T>(T) -> T
            // bitcast<T>(S) -> T
            result_type = lhs;
        } else if (rhs_res_inst == .vector) {
            const rhs_vec_type = astgen.getInst(rhs_res_inst.vector.elem_type);

            if (rhs_res_inst.vector.size == .two and
                rhs_vec_type == .float and rhs_vec_type.float.type == .f16)
            {
                // bitcast<T>(vec2<f16>) -> T
                result_type = lhs;
            }
        }
    } else if (lhs_inst == .vector) {
        if (rhs_is_32bit) {
            const lhs_vec_type = astgen.getInst(lhs_inst.vector.elem_type);

            if (lhs_inst.vector.size == .two and
                lhs_vec_type == .float and lhs_vec_type.float.type == .f16)
            {
                // bitcast<vec2<f16>>(T) -> vec2<f16>
                result_type = lhs;
            }
        } else if (rhs_res_inst == .vector) {
            const lhs_vec_type = astgen.getInst(lhs_inst.vector.elem_type);
            const rhs_vec_type = astgen.getInst(rhs_res_inst.vector.elem_type);

            const lhs_vec_is_32bit = switch (lhs_vec_type) {
                .int => |int| int.type == .u32 or int.type == .i32,
                .float => |float| float.type == .f32,
                else => false,
            };
            const rhs_vec_is_32bit = switch (rhs_vec_type) {
                .int => |int| int.type == .u32 or int.type == .i32,
                .float => |float| float.type == .f32,
                else => false,
            };

            if (lhs_vec_is_32bit) {
                if (rhs_vec_is_32bit) {
                    if (lhs_inst.vector.size == rhs_res_inst.vector.size) {
                        if (lhs_inst.vector.elem_type == rhs_res_inst.vector.elem_type) {
                            // bitcast<vecN<T>>(vecN<T>) -> vecN<T>
                            result_type = lhs;
                        } else {
                            // bitcast<vecN<T>>(vecN<S>) -> T
                            result_type = lhs_inst.vector.elem_type;
                        }
                    }
                } else if (rhs_vec_type == .float and rhs_vec_type.float.type == .f16) {
                    if (lhs_inst.vector.size == .two and
                        rhs_res_inst.vector.size == .four)
                    {
                        // bitcast<vec2<T>>(vec4<f16>) -> vec2<T>
                        result_type = lhs;
                    }
                }
            } else if (lhs_vec_type == .float and lhs_vec_type.float.type == .f16) {
                if (rhs_res_inst.vector.size == .two and
                    lhs_inst.vector.size == .four)
                {
                    // bitcast<vec4<f16>>(vec2<T>) -> vec4<f16>
                    result_type = lhs;
                }
            }
        }
    }

    if (result_type != .none) {
        const inst = try astgen.addInst(.{
            .bitcast = .{
                .type = lhs,
                .expr = rhs,
                .result_type = result_type,
            },
        });
        return inst;
    }

    try astgen.errors.add(
        node_rhs_loc,
        "cannot cast '{s}' into '{s}'",
        .{ node_rhs_loc.slice(astgen.tree.source), node_lhs_loc.slice(astgen.tree.source) },
        null,
    );
    return error.AnalysisFail;
}

fn genBuiltinAllAny(astgen: *AstGen, scope: *Scope, node: NodeIndex, all: bool) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 1, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len != 1) {
        return astgen.failArgCountMismatch(node_loc, 1, arg_nodes.len);
    }

    const arg = try astgen.genExpr(scope, arg_nodes[0]);
    const arg_res = try astgen.resolve(arg);
    switch (astgen.getInst(arg_res)) {
        .bool => return arg,
        .vector => |vec| {
            if (astgen.getInst(vec.elem_type) != .bool) {
                try astgen.errors.add(node_loc, "invalid vector element type", .{}, null);
                return error.AnalysisFail;
            }

            const result_type = try astgen.addInst(.{ .bool = .{ .value = null } });
            return astgen.addInst(.{ .unary_intrinsic = .{
                .op = if (all) .all else .any,
                .expr = arg,
                .result_type = result_type,
            } });
        },
        else => {
            try astgen.errors.add(node_loc, "type mismatch", .{}, null);
            return error.AnalysisFail;
        },
    }
}

fn genBuiltinSelect(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 3, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len != 3) {
        return astgen.failArgCountMismatch(node_loc, 3, arg_nodes.len);
    }

    const arg1 = try astgen.genExpr(scope, arg_nodes[0]);
    const arg2 = try astgen.genExpr(scope, arg_nodes[1]);
    const arg3 = try astgen.genExpr(scope, arg_nodes[2]);
    const arg1_res = try astgen.resolve(arg1);
    const arg2_res = try astgen.resolve(arg2);
    const arg3_res = try astgen.resolve(arg3);

    if (!try astgen.coerce(arg2_res, arg1_res)) {
        try astgen.errors.add(node_loc, "type mismatch", .{}, null);
        return error.AnalysisFail;
    }

    switch (astgen.getInst(arg3_res)) {
        .bool => {
            return astgen.addInst(.{
                .select = .{
                    .type = arg1_res,
                    .true = arg1,
                    .false = arg2,
                    .cond = arg3,
                },
            });
        },
        .vector => |vec| {
            if (astgen.getInst(vec.elem_type) != .bool) {
                try astgen.errors.add(node_loc, "invalid vector element type", .{}, null);
                return error.AnalysisFail;
            }

            if (astgen.getInst(arg1_res) != .vector) {
                try astgen.errors.add(node_loc, "'true' and 'false' must be vector", .{}, null);
                return error.AnalysisFail;
            }

            return astgen.addInst(.{
                .select = .{
                    .type = arg1_res,
                    .true = arg1,
                    .false = arg2,
                    .cond = arg2,
                },
            });
        },
        else => {
            try astgen.errors.add(node_loc, "type mismatch", .{}, null);
            return error.AnalysisFail;
        },
    }
}

fn genDerivativeBuiltin(
    astgen: *AstGen,
    scope: *Scope,
    node: NodeIndex,
    comptime op: Inst.UnaryIntrinsic.Op,
) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);

    if (astgen.current_fn_scope.tag.@"fn".stage != .fragment) {
        try astgen.errors.add(
            node_loc,
            "invalid builtin in {s} stage",
            .{@tagName(astgen.current_fn_scope.tag.@"fn".stage)},
            null,
        );
        return error.AnalysisFail;
    }

    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 1, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len != 1) {
        return astgen.failArgCountMismatch(node_loc, 1, arg_nodes.len);
    }

    const arg = try astgen.genExpr(scope, arg_nodes[0]);
    const arg_res = try astgen.resolve(arg);
    const inst = Inst{ .unary_intrinsic = .{
        .op = op,
        .expr = arg,
        .result_type = arg_res,
    } };
    switch (astgen.getInst(arg_res)) {
        .float => |float| {
            if (float.type == .f32) {
                return astgen.addInst(inst);
            }
        },
        .vector => |vec| {
            switch (astgen.getInst(vec.elem_type)) {
                .float => |float| {
                    if (float.type == .f32) {
                        return astgen.addInst(inst);
                    }
                },
                else => {},
            }
        },
        else => {},
    }

    try astgen.errors.add(node_loc, "type mismatch", .{}, null);
    return error.AnalysisFail;
}

fn genGenericUnaryBuiltin(
    astgen: *AstGen,
    scope: *Scope,
    node: NodeIndex,
    comptime op: Inst.UnaryIntrinsic.Op,
    comptime int_limit: []const Inst.Int.Type,
    comptime float_limit: []const Inst.Float.Type,
    comptime vector_only: bool,
    comptime scalar_result: bool,
) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 1, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len != 1) {
        return astgen.failArgCountMismatch(node_loc, 1, arg_nodes.len);
    }

    const arg = try astgen.genExpr(scope, arg_nodes[0]);
    const arg_res = try astgen.resolve(arg);
    var result_type = arg_res;

    switch (astgen.getInst(arg_res)) {
        .int => |int| if (vector_only or indexOf(Inst.Int.Type, int_limit, int.type) == null) {
            try astgen.errors.add(node_loc, "type mismatch", .{}, null);
            return error.AnalysisFail;
        },
        .float => |float| if (vector_only or indexOf(Inst.Float.Type, float_limit, float.type) == null) {
            try astgen.errors.add(node_loc, "type mismatch", .{}, null);
            return error.AnalysisFail;
        },
        .vector => |vec| {
            switch (astgen.getInst(vec.elem_type)) {
                .bool => {
                    try astgen.errors.add(node_loc, "invalid vector element type", .{}, null);
                    return error.AnalysisFail;
                },
                .int => |int| if (indexOf(Inst.Int.Type, int_limit, int.type) == null) {
                    try astgen.errors.add(node_loc, "invalid vector element type", .{}, null);
                    return error.AnalysisFail;
                },
                .float => |float| if (indexOf(Inst.Float.Type, float_limit, float.type) == null) {
                    try astgen.errors.add(node_loc, "invalid vector element type", .{}, null);
                    return error.AnalysisFail;
                },
                else => {},
            }

            if (scalar_result) {
                result_type = vec.elem_type;
            }
        },
        else => {
            try astgen.errors.add(node_loc, "type mismatch", .{}, null);
            return error.AnalysisFail;
        },
    }

    return astgen.addInst(.{
        .unary_intrinsic = .{
            .op = op,
            .expr = arg,
            .result_type = result_type,
        },
    });
}

fn genGenericBinaryBuiltin(
    astgen: *AstGen,
    scope: *Scope,
    node: NodeIndex,
    comptime op: Inst.BinaryIntrinsic.Op,
    comptime form: enum { any_in_any_out, any_in_scalar_out, vector_in_scalar_out },
    comptime allow_int: bool,
) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 2, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len != 2) {
        return astgen.failArgCountMismatch(node_loc, 2, arg_nodes.len);
    }

    const arg1 = try astgen.genExpr(scope, arg_nodes[0]);
    const arg2 = try astgen.genExpr(scope, arg_nodes[1]);
    const arg1_res = try astgen.resolve(arg1);
    const arg2_res = try astgen.resolve(arg2);
    var result_type = arg1_res;

    switch (astgen.getInst(arg1_res)) {
        .float => if (form == .vector_in_scalar_out) {
            try astgen.errors.add(node_loc, "type mismatch", .{}, null);
            return error.AnalysisFail;
        },
        .int => if (!allow_int or form == .vector_in_scalar_out) {
            try astgen.errors.add(node_loc, "type mismatch", .{}, null);
            return error.AnalysisFail;
        },
        .vector => |vec| {
            switch (astgen.getInst(vec.elem_type)) {
                .bool => {
                    try astgen.errors.add(node_loc, "invalid vector element type", .{}, null);
                    return error.AnalysisFail;
                },
                .int => if (!allow_int) {
                    try astgen.errors.add(node_loc, "invalid vector element type", .{}, null);
                    return error.AnalysisFail;
                },
                else => {},
            }

            switch (form) {
                .any_in_scalar_out, .vector_in_scalar_out => result_type = vec.elem_type,
                .any_in_any_out => {},
            }
        },
        else => {
            try astgen.errors.add(node_loc, "type mismatch", .{}, null);
            return error.AnalysisFail;
        },
    }

    if (!try astgen.coerce(arg2_res, arg1_res)) {
        try astgen.errors.add(node_loc, "type mismatch", .{}, null);
        return error.AnalysisFail;
    }

    return astgen.addInst(.{ .binary_intrinsic = .{
        .op = op,
        .lhs = arg1,
        .rhs = arg2,
        .lhs_type = arg1_res,
        .rhs_type = arg2_res,
        .result_type = result_type,
    } });
}

fn genGenericFloatTripleBuiltin(
    astgen: *AstGen,
    scope: *Scope,
    node: NodeIndex,
    comptime op: Inst.TripleIntrinsic.Op,
    comptime scalar_float_arg3: bool,
) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 3, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len != 3) {
        return astgen.failArgCountMismatch(node_loc, 3, arg_nodes.len);
    }

    const a1 = try astgen.genExpr(scope, arg_nodes[0]);
    const a2 = try astgen.genExpr(scope, arg_nodes[1]);
    const a3 = try astgen.genExpr(scope, arg_nodes[2]);
    const a1_res = try astgen.resolve(a1);
    const a2_res = try astgen.resolve(a2);
    const a3_res = try astgen.resolve(a3);

    if (!try astgen.coerce(a2_res, a1_res)) {
        try astgen.errors.add(node_loc, "type mismatch", .{}, null);
        return error.AnalysisFail;
    }

    if (scalar_float_arg3) {
        switch (astgen.getInst(a3_res)) {
            .float => {},
            else => {
                try astgen.errors.add(node_loc, "type mismatch", .{}, null);
                return error.AnalysisFail;
            },
        }
    } else {
        if (!try astgen.coerce(a3_res, a1_res)) {
            try astgen.errors.add(node_loc, "type mismatch", .{}, null);
            return error.AnalysisFail;
        }
    }

    if (astgen.getInst(a1_res) == .float or
        (astgen.getInst(a1_res) == .vector and
        astgen.getInst(astgen.getInst(a1_res).vector.elem_type) == .float))
    {
        return astgen.addInst(.{
            .triple_intrinsic = .{
                .op = op,
                .result_type = a1_res,
                .a1_type = a1_res,
                .a2_type = a2_res,
                .a3_type = a3_res,
                .a1 = a1,
                .a2 = a2,
                .a3 = a3,
            },
        });
    }

    try astgen.errors.add(node_loc, "type mismatch", .{}, null);
    return error.AnalysisFail;
}

fn genArrayLengthBuiltin(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    astgen.has_array_length = true;

    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 1, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len != 1) {
        return astgen.failArgCountMismatch(node_loc, 1, arg_nodes.len);
    }

    const arg_node = arg_nodes[0];
    const arg_node_loc = astgen.tree.nodeLoc(arg_node);
    const arg = try astgen.genExpr(scope, arg_node);
    const arg_res = try astgen.resolve(arg);
    const arg_res_inst = astgen.getInst(arg_res);

    if (arg_res_inst == .ptr_type) {
        const ptr_elem_inst = astgen.getInst(arg_res_inst.ptr_type.elem_type);
        if (ptr_elem_inst == .array) {
            const result_type = try astgen.addInst(.{ .int = .{ .type = .u32, .value = null } });
            return astgen.addInst(.{ .unary_intrinsic = .{
                .op = .array_length,
                .expr = arg,
                .result_type = result_type,
            } });
        }
    }

    try astgen.errors.add(arg_node_loc, "type mismatch", .{}, null);
    return error.AnalysisFail;
}

fn genTextureDimensionsBuiltin(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 1, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len < 1) {
        return astgen.failArgCountMismatch(node_loc, 1, arg_nodes.len);
    }

    const a1_node = arg_nodes[0];
    const a1_node_loc = astgen.tree.nodeLoc(a1_node);
    const a1 = try astgen.genExpr(scope, a1_node);
    const a1_res = try astgen.resolve(a1);
    const a1_inst = astgen.getInst(a1_res);

    if (a1_inst != .texture_type) {
        try astgen.errors.add(a1_node_loc, "expected a texture type", .{}, null);
        return error.AnalysisFail;
    }

    var level = InstIndex.none;

    switch (a1_inst.texture_type.kind) {
        .sampled_2d,
        .sampled_2d_array,
        .sampled_cube,
        .sampled_cube_array,
        .multisampled_2d,
        .multisampled_depth_2d,
        .storage_2d,
        .storage_2d_array,
        .depth_2d,
        .depth_2d_array,
        .depth_cube,
        .depth_cube_array,
        => {
            if (arg_nodes.len > 1) {
                const a2_node = arg_nodes[1];
                const a2_node_loc = astgen.tree.nodeLoc(a2_node);
                const a2 = try astgen.genExpr(scope, a2_node);
                const a2_res = try astgen.resolve(a2);
                const a2_inst = astgen.getInst(a2_res);

                if (a2_inst != .int) {
                    try astgen.errors.add(a2_node_loc, "expected i32 or u32", .{}, null);
                    return error.AnalysisFail;
                }

                level = a2;
            }
        },
        else => {
            try astgen.errors.add(a1_node_loc, "invalid texture", .{}, null);
            return error.AnalysisFail;
        },
    }

    const result_type = try astgen.addInst(.{ .vector = .{
        .elem_type = try astgen.addInst(.{ .int = .{ .type = .u32, .value = null } }),
        .size = .two,
        .value = null,
    } });
    return astgen.addInst(.{ .texture_dimension = .{
        .kind = a1_inst.texture_type.kind,
        .texture = a1,
        .level = level,
        .result_type = result_type,
    } });
}

fn genTextureLoadBuiltin(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 3, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len < 3) {
        return astgen.failArgCountMismatch(node_loc, 3, arg_nodes.len);
    }

    const a1_node = arg_nodes[0];
    const a1_node_loc = astgen.tree.nodeLoc(a1_node);
    const a1 = try astgen.genExpr(scope, a1_node);
    const a1_res = try astgen.resolve(a1);
    const a1_inst = astgen.getInst(a1_res);

    const a2_node = arg_nodes[1];
    const a2_node_loc = astgen.tree.nodeLoc(a2_node);
    const a2 = try astgen.genExpr(scope, a2_node);
    const a2_res = try astgen.resolve(a2);
    const a2_inst = astgen.getInst(a2_res);

    const a3_node = arg_nodes[2];
    const a3_node_loc = astgen.tree.nodeLoc(a3_node);
    const a3 = try astgen.genExpr(scope, a3_node);
    const a3_res = try astgen.resolve(a3);
    const a3_inst = astgen.getInst(a3_res);

    if (a1_inst != .texture_type) {
        try astgen.errors.add(a1_node_loc, "expected a texture type", .{}, null);
        return error.AnalysisFail;
    }

    if (a2_inst != .vector or a2_inst.vector.size != .two or astgen.getInst(a2_inst.vector.elem_type) != .int) {
        try astgen.errors.add(a2_node_loc, "expected vec2<i32> or vec2<u32>", .{}, null);
        return error.AnalysisFail;
    }

    if (a3_inst != .int) {
        try astgen.errors.add(a3_node_loc, "expected i32 or u32", .{}, null);
        return error.AnalysisFail;
    }

    const result_type = switch (a1_inst.texture_type.kind) {
        .sampled_2d => try astgen.addInst(.{ .vector = .{
            .elem_type = a1_inst.texture_type.elem_type,
            .size = .four,
            .value = null,
        } }),
        .depth_2d => try astgen.addInst(.{ .float = .{ .type = .f32, .value = null } }),
        else => {
            try astgen.errors.add(a1_node_loc, "invalid texture", .{}, null);
            return error.AnalysisFail;
        },
    };

    return astgen.addInst(.{ .texture_load = .{
        .kind = a1_inst.texture_type.kind,
        .texture = a1,
        .coords = a2,
        .level = a3,
        .result_type = result_type,
    } });
}

fn genTextureStoreBuiltin(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 3, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len < 3) {
        return astgen.failArgCountMismatch(node_loc, 3, arg_nodes.len);
    }

    const a1_node = arg_nodes[0];
    const a1_node_loc = astgen.tree.nodeLoc(a1_node);
    const a1 = try astgen.genExpr(scope, a1_node);
    const a1_res = try astgen.resolve(a1);
    const a1_inst = astgen.getInst(a1_res);

    const a2_node = arg_nodes[1];
    const a2_node_loc = astgen.tree.nodeLoc(a2_node);
    const a2 = try astgen.genExpr(scope, a2_node);
    const a2_res = try astgen.resolve(a2);
    const a2_inst = astgen.getInst(a2_res);

    const a3_node = arg_nodes[2];
    const a3_node_loc = astgen.tree.nodeLoc(a3_node);
    const a3 = try astgen.genExpr(scope, a3_node);
    const a3_res = try astgen.resolve(a3);
    const a3_inst = astgen.getInst(a3_res);

    if (a1_inst != .texture_type) {
        try astgen.errors.add(a1_node_loc, "expected a texture type", .{}, null);
        return error.AnalysisFail;
    }

    if (a2_inst != .vector or a2_inst.vector.size != .two or astgen.getInst(a2_inst.vector.elem_type) != .int) {
        try astgen.errors.add(a2_node_loc, "expected vec2<i32> or vec2<u32>", .{}, null);
        return error.AnalysisFail;
    }

    if (a3_inst != .vector or a3_inst.vector.size != .four) {
        try astgen.errors.add(a3_node_loc, "expected vec4", .{}, null);
        return error.AnalysisFail;
    }

    switch (a1_inst.texture_type.kind) {
        .storage_2d => {},
        else => {
            try astgen.errors.add(a1_node_loc, "invalid texture", .{}, null);
            return error.AnalysisFail;
        },
    }

    return astgen.addInst(.{ .texture_store = .{
        .kind = a1_inst.texture_type.kind,
        .texture = a1,
        .coords = a2,
        .value = a3,
    } });
}

fn genSimpleBuiltin(astgen: *AstGen, comptime op: Air.Inst.NilIntrinsic) !InstIndex {
    return astgen.addInst(.{ .nil_intrinsic = op });
}

fn genTextureSampleBuiltin(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 3, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len < 3) {
        return astgen.failArgCountMismatch(node_loc, 3, arg_nodes.len);
    }

    const a1_node = arg_nodes[0];
    const a1_node_loc = astgen.tree.nodeLoc(a1_node);
    const a1 = try astgen.genExpr(scope, a1_node);
    const a1_res = try astgen.resolve(a1);
    const a1_inst = astgen.getInst(a1_res);

    const a2_node = arg_nodes[1];
    const a2_node_loc = astgen.tree.nodeLoc(a2_node);
    const a2 = try astgen.genExpr(scope, a2_node);
    const a2_res = try astgen.resolve(a2);
    const a2_inst = astgen.getInst(a2_res);

    const a3_node = arg_nodes[2];
    const a3_node_loc = astgen.tree.nodeLoc(a3_node);
    const a3 = try astgen.genExpr(scope, a3_node);
    const a3_res = try astgen.resolve(a3);
    const a3_inst = astgen.getInst(a3_res);

    if (a1_inst != .texture_type) {
        // TODO: depth textures
        try astgen.errors.add(a1_node_loc, "expected a texture type", .{}, null);
        return error.AnalysisFail;
    }

    if (a2_inst != .sampler_type) {
        try astgen.errors.add(a2_node_loc, "expected a sampler", .{}, null);
        return error.AnalysisFail;
    }

    switch (a1_inst.texture_type.kind) {
        .sampled_1d => {
            if (a3_inst != .float) {
                try astgen.errors.add(a3_node_loc, "expected a f32", .{}, null);
                return error.AnalysisFail;
            }
        },
        .sampled_2d, .sampled_2d_array, .depth_2d, .depth_2d_array => {
            if (a3_inst != .vector or a3_inst.vector.size != .two) {
                try astgen.errors.add(a3_node_loc, "expected a vec2<f32>", .{}, null);
                return error.AnalysisFail;
            }
        },
        .sampled_3d, .sampled_cube, .sampled_cube_array, .depth_cube, .depth_cube_array => {
            if (a3_inst != .vector or a3_inst.vector.size != .three) {
                try astgen.errors.add(a3_node_loc, "expected a vec3<f32>", .{}, null);
                return error.AnalysisFail;
            }
        },
        else => {
            try astgen.errors.add(a3_node_loc, "invalid texture", .{}, null);
            return error.AnalysisFail;
        },
    }

    var offset = InstIndex.none;
    var array_index = InstIndex.none;

    switch (a1_inst.texture_type.kind) {
        .sampled_2d, .sampled_3d, .sampled_cube, .depth_2d, .depth_cube => {
            if (arg_nodes.len == 4) {
                const a4_node = arg_nodes[3];
                const a4_node_loc = astgen.tree.nodeLoc(a4_node);
                const a4 = try astgen.genExpr(scope, a4_node);
                const a4_res = try astgen.resolve(a4);
                const a4_inst = astgen.getInst(a4_res);
                offset = a4;

                switch (a1_inst.texture_type.kind) {
                    .sampled_3d, .sampled_cube, .depth_cube => {
                        if (a4_inst != .vector or a4_inst.vector.size != .three) {
                            try astgen.errors.add(a4_node_loc, "expected a vec3<i32>", .{}, null);
                            return error.AnalysisFail;
                        }
                    },
                    .sampled_2d, .depth_2d => if (a4_inst != .vector or a4_inst.vector.size != .two) {
                        try astgen.errors.add(a4_node_loc, "expected a vec2<i32>", .{}, null);
                        return error.AnalysisFail;
                    },
                    else => unreachable,
                }
            }
        },
        .sampled_2d_array, .sampled_cube_array, .depth_2d_array, .depth_cube_array => {
            if (arg_nodes.len < 4) {
                return astgen.failArgCountMismatch(node_loc, 4, arg_nodes.len);
            }

            const a4_node = arg_nodes[3];
            const a4_node_loc = astgen.tree.nodeLoc(a4_node);
            const a4 = try astgen.genExpr(scope, a4_node);
            const a4_res = try astgen.resolve(a4);
            const a4_inst = astgen.getInst(a4_res);
            array_index = a4;

            if (a4_inst != .int) {
                try astgen.errors.add(a4_node_loc, "expected i32 or u32", .{}, null);
                return error.AnalysisFail;
            }

            if (arg_nodes.len == 5) {
                const a5_node = arg_nodes[5];
                const a5_node_loc = astgen.tree.nodeLoc(a5_node);
                const a5 = try astgen.genExpr(scope, a5_node);
                const a5_res = try astgen.resolve(a5);
                const a5_inst = astgen.getInst(a5_res);
                offset = a5;

                switch (a1_inst.texture_type.kind) {
                    .sampled_cube_array, .depth_cube_array => {
                        if (a5_inst != .vector or a5_inst.vector.size != .three) {
                            try astgen.errors.add(a5_node_loc, "expected a vec3<i32>", .{}, null);
                            return error.AnalysisFail;
                        }
                    },
                    .sampled_2d_array, .depth_2d_array => {
                        if (a5_inst != .vector or a5_inst.vector.size != .two) {
                            try astgen.errors.add(a5_node_loc, "expected a vec2<i32>", .{}, null);
                            return error.AnalysisFail;
                        }
                    },
                    else => unreachable,
                }
            }
        },
        else => unreachable,
    }

    const result_type = switch (a1_inst.texture_type.kind) {
        .depth_2d,
        .depth_2d_array,
        .depth_cube,
        .depth_cube_array,
        => try astgen.addInst(.{ .float = .{ .type = .f32, .value = null } }),
        else => try astgen.addInst(.{ .vector = .{
            .elem_type = try astgen.addInst(.{ .float = .{ .type = .f32, .value = null } }),
            .size = .four,
            .value = null,
        } }),
    };
    return astgen.addInst(.{ .texture_sample = .{
        .kind = a1_inst.texture_type.kind,
        .texture_type = a1_res,
        .texture = a1,
        .sampler = a2,
        .coords = a3,
        .offset = offset,
        .array_index = array_index,
        .result_type = result_type,
    } });
}

// TODO: Partial implementation
fn genTextureSampleLevelBuiltin(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 4, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len < 4) {
        return astgen.failArgCountMismatch(node_loc, 4, arg_nodes.len);
    }

    const a1_node = arg_nodes[0];
    const a1_node_loc = astgen.tree.nodeLoc(a1_node);
    const a1 = try astgen.genExpr(scope, a1_node);
    const a1_res = try astgen.resolve(a1);
    const a1_inst = astgen.getInst(a1_res);

    const a2_node = arg_nodes[1];
    const a2_node_loc = astgen.tree.nodeLoc(a2_node);
    const a2 = try astgen.genExpr(scope, a2_node);
    const a2_res = try astgen.resolve(a2);
    const a2_inst = astgen.getInst(a2_res);

    const a3_node = arg_nodes[2];
    const a3_node_loc = astgen.tree.nodeLoc(a3_node);
    const a3 = try astgen.genExpr(scope, a3_node);
    const a3_res = try astgen.resolve(a3);
    const a3_inst = astgen.getInst(a3_res);

    const a4_node = arg_nodes[3];
    const a4_node_loc = astgen.tree.nodeLoc(a4_node);
    const a4 = try astgen.genExpr(scope, a4_node);
    const a4_res = try astgen.resolve(a4);
    const a4_inst = astgen.getInst(a4_res);

    if (a1_inst != .texture_type) {
        try astgen.errors.add(a1_node_loc, "expected a texture type", .{}, null);
        return error.AnalysisFail;
    }

    switch (a1_inst.texture_type.kind) {
        .sampled_2d => {},
        else => {
            try astgen.errors.add(a1_node_loc, "invalid texture", .{}, null);
            return error.AnalysisFail;
        },
    }

    if (a2_inst != .sampler_type) {
        try astgen.errors.add(a2_node_loc, "expected a sampler", .{}, null);
        return error.AnalysisFail;
    }

    if (a3_inst != .vector or a3_inst.vector.size != .two) {
        try astgen.errors.add(a3_node_loc, "expected a vec2<f32>", .{}, null);
        return error.AnalysisFail;
    }

    if (a4_inst != .float) {
        try astgen.errors.add(a4_node_loc, "expected f32", .{}, null);
        return error.AnalysisFail;
    }

    const result_type = try astgen.addInst(.{ .vector = .{
        .elem_type = try astgen.addInst(.{ .float = .{ .type = .f32, .value = null } }),
        .size = .four,
        .value = null,
    } });
    return astgen.addInst(.{ .texture_sample = .{
        .kind = a1_inst.texture_type.kind,
        .texture_type = a1_res,
        .texture = a1,
        .sampler = a2,
        .coords = a3,
        .result_type = result_type,
        .operands = .{ .level = a4 },
    } });
}

fn genTextureSampleGradBuiltin(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_loc = astgen.tree.nodeLoc(node);
    const node_lhs = astgen.tree.nodeLHS(node);
    if (node_lhs == .none) {
        return astgen.failArgCountMismatch(node_loc, 4, 0);
    }

    const arg_nodes = astgen.tree.spanToList(node_lhs);
    if (arg_nodes.len < 4) {
        return astgen.failArgCountMismatch(node_loc, 4, arg_nodes.len);
    }

    const a1_node = arg_nodes[0];
    const a1_node_loc = astgen.tree.nodeLoc(a1_node);
    const a1 = try astgen.genExpr(scope, a1_node);
    const a1_res = try astgen.resolve(a1);
    const a1_inst = astgen.getInst(a1_res);

    const a2_node = arg_nodes[1];
    const a2_node_loc = astgen.tree.nodeLoc(a2_node);
    const a2 = try astgen.genExpr(scope, a2_node);
    const a2_res = try astgen.resolve(a2);
    const a2_inst = astgen.getInst(a2_res);

    const a3_node = arg_nodes[2];
    const a3_node_loc = astgen.tree.nodeLoc(a3_node);
    const a3 = try astgen.genExpr(scope, a3_node);
    const a3_res = try astgen.resolve(a3);
    const a3_inst = astgen.getInst(a3_res);

    const a4_node = arg_nodes[3];
    const a4_node_loc = astgen.tree.nodeLoc(a4_node);
    const a4 = try astgen.genExpr(scope, a4_node);
    const a4_res = try astgen.resolve(a4);
    const a4_inst = astgen.getInst(a4_res);

    const a5_node = arg_nodes[3];
    const a5_node_loc = astgen.tree.nodeLoc(a5_node);
    const a5 = try astgen.genExpr(scope, a5_node);
    const a5_res = try astgen.resolve(a5);
    const a5_inst = astgen.getInst(a5_res);

    if (a1_inst != .texture_type) {
        try astgen.errors.add(a1_node_loc, "expected a texture type", .{}, null);
        return error.AnalysisFail;
    }

    switch (a1_inst.texture_type.kind) {
        .sampled_2d => {},
        else => {
            try astgen.errors.add(a1_node_loc, "invalid texture", .{}, null);
            return error.AnalysisFail;
        },
    }

    if (a2_inst != .sampler_type) {
        try astgen.errors.add(a2_node_loc, "expected a sampler", .{}, null);
        return error.AnalysisFail;
    }

    if (a3_inst != .vector or
        astgen.getInst(a4_inst.vector.elem_type) != .float or
        a3_inst.vector.size != .two)
    {
        try astgen.errors.add(a3_node_loc, "expected a vec2<f32>", .{}, null);
        return error.AnalysisFail;
    }

    if (a4_inst != .vector or
        astgen.getInst(a4_inst.vector.elem_type) != .float or
        a4_inst.vector.size != .two)
    {
        try astgen.errors.add(a4_node_loc, "expected vec2<f32>", .{}, null);
        return error.AnalysisFail;
    }

    if (a5_inst != .vector or
        astgen.getInst(a5_inst.vector.elem_type) != .float or
        a5_inst.vector.size != .two)
    {
        try astgen.errors.add(a5_node_loc, "expected vec2<f32>", .{}, null);
        return error.AnalysisFail;
    }

    const result_type = try astgen.addInst(.{ .vector = .{
        .elem_type = try astgen.addInst(.{ .float = .{ .type = .f32, .value = null } }),
        .size = .four,
        .value = null,
    } });
    return astgen.addInst(.{ .texture_sample = .{
        .kind = a1_inst.texture_type.kind,
        .texture_type = a1_res,
        .texture = a1,
        .sampler = a2,
        .coords = a3,
        .result_type = result_type,
        .operands = .{ .grad = .{ .dpdx = a4, .dpdy = a5 } },
    } });
}

fn genVarRef(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const inst_idx = try astgen.findSymbol(scope, astgen.tree.nodeToken(node));
    switch (astgen.getInst(inst_idx)) {
        .@"var" => |inst| {
            if (inst.addr_space != .function) {
                try astgen.global_var_refs.put(astgen.allocator, inst_idx, {});
            }
        },
        else => {},
    }

    return astgen.addInst(.{ .var_ref = inst_idx });
}

fn genIndexAccess(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const base = try astgen.genExpr(scope, astgen.tree.nodeLHS(node));
    const base_type = try astgen.resolve(base);

    switch (astgen.getInst(base_type)) {
        .vector, .matrix, .array => {},
        else => {
            try astgen.errors.add(
                astgen.tree.nodeLoc(astgen.tree.nodeRHS(node)),
                "cannot access index of a non-array",
                .{},
                null,
            );
            return error.AnalysisFail;
        },
    }

    const rhs = try astgen.genExpr(scope, astgen.tree.nodeRHS(node));
    const rhs_res = try astgen.resolve(rhs);
    const elem_type = switch (astgen.getInst(base_type)) {
        inline .vector, .array => |ty| ty.elem_type,
        .matrix => |ty| try astgen.addInst(.{ .vector = .{
            .elem_type = ty.elem_type,
            .size = ty.rows,
            .value = null,
        } }),
        else => unreachable,
    };

    if (astgen.getInst(rhs_res) == .int) {
        const inst = try astgen.addInst(.{
            .index_access = .{
                .base = base,
                .type = elem_type,
                .index = rhs,
            },
        });
        return inst;
    }

    try astgen.errors.add(
        astgen.tree.nodeLoc(astgen.tree.nodeRHS(node)),
        "index must be an integer",
        .{},
        null,
    );
    return error.AnalysisFail;
}

fn genFieldAccess(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const base = try astgen.genExpr(scope, astgen.tree.nodeLHS(node));
    const base_type = try astgen.resolve(base);
    const field_node = astgen.tree.nodeRHS(node).asTokenIndex();
    const field_name = astgen.tree.tokenLoc(field_node).slice(astgen.tree.source);

    switch (astgen.getInst(base_type)) {
        .vector => |base_vec| {
            if (field_name.len > 4) {
                try astgen.errors.add(
                    astgen.tree.tokenLoc(field_node),
                    "invalid swizzle name",
                    .{},
                    null,
                );
                return error.AnalysisFail;
            }

            var pattern: [4]Inst.SwizzleAccess.Component = undefined;
            for (field_name, 0..) |c, i| {
                pattern[i] = switch (c) {
                    'x', 'r' => .x,
                    'y', 'g' => .y,
                    'z', 'b' => .z,
                    'w', 'a' => .w,
                    else => {
                        try astgen.errors.add(
                            astgen.tree.tokenLoc(field_node),
                            "invalid swizzle name",
                            .{},
                            null,
                        );
                        return error.AnalysisFail;
                    },
                };
            }

            const inst = try astgen.addInst(.{
                .swizzle_access = .{
                    .base = base,
                    .type = base_vec.elem_type,
                    .size = @enumFromInt(field_name.len),
                    .pattern = pattern,
                },
            });
            return inst;
        },
        .@"struct" => |@"struct"| {
            const struct_members = @"struct".members;
            for (astgen.refToList(struct_members)) |member| {
                const member_data = astgen.getInst(member).struct_member;
                if (std.mem.eql(u8, field_name, astgen.getStr(member_data.name))) {
                    if (astgen.current_fn_scope.tag.@"fn".flattened_params.get(member)) |fv| {
                        return try astgen.addInst(.{ .var_ref = fv });
                    }

                    const inst = try astgen.addInst(.{
                        .field_access = .{
                            .base = base,
                            .field = member,
                            .name = member_data.name,
                        },
                    });
                    return inst;
                }
            }

            try astgen.errors.add(
                astgen.tree.nodeLoc(node),
                "struct '{s}' has no member named '{s}'",
                .{
                    astgen.getStr(@"struct".name),
                    field_name,
                },
                null,
            );
            return error.AnalysisFail;
        },
        else => {
            try astgen.errors.add(
                astgen.tree.nodeLoc(node),
                "expected struct type",
                .{},
                null,
            );
            return error.AnalysisFail;
        },
    }
}

fn genType(astgen: *AstGen, scope: *Scope, node: NodeIndex) error{ AnalysisFail, OutOfMemory }!InstIndex {
    const inst = switch (astgen.tree.nodeTag(node)) {
        .bool_type => try astgen.addInst(.{ .bool = .{ .value = null } }),
        .number_type => try astgen.genNumberType(node),
        .vector_type => try astgen.genVectorType(scope, node),
        .matrix_type => try astgen.genMatrixType(scope, node),
        .atomic_type => try astgen.genAtomicType(scope, node),
        .array_type => try astgen.genArray(scope, node, null),
        .ptr_type => try astgen.genPtrType(scope, node),
        .sampler_type => try astgen.genSamplerType(node),
        .sampled_texture_type => try astgen.genSampledTextureType(scope, node),
        .multisampled_texture_type => try astgen.genMultisampledTextureType(scope, node),
        .storage_texture_type => try astgen.genStorageTextureType(node),
        .depth_texture_type => try astgen.genDepthTextureType(node),
        .external_texture_type => try astgen.addInst(.external_texture_type),
        .ident => {
            const node_loc = astgen.tree.nodeLoc(node);
            const decl = try astgen.findSymbol(scope, astgen.tree.nodeToken(node));
            switch (astgen.getInst(decl)) {
                .bool,
                .int,
                .float,
                .vector,
                .matrix,
                .atomic_type,
                .array,
                .ptr_type,
                .sampler_type,
                .comparison_sampler_type,
                .external_texture_type,
                .texture_type,
                .@"struct",
                => return decl,
                else => {
                    try astgen.errors.add(
                        node_loc,
                        "'{s}' is not a type",
                        .{node_loc.slice(astgen.tree.source)},
                        null,
                    );
                    return error.AnalysisFail;
                },
            }
        },
        else => unreachable,
    };
    return inst;
}

fn genNumberType(astgen: *AstGen, node: NodeIndex) !InstIndex {
    const token = astgen.tree.nodeToken(node);
    const token_tag = astgen.tree.tokenTag(token);
    return astgen.addInst(switch (token_tag) {
        .k_u32 => .{ .int = .{ .type = .u32, .value = null } },
        .k_i32 => .{ .int = .{ .type = .i32, .value = null } },
        .k_f32 => .{ .float = .{ .type = .f32, .value = null } },
        .k_f16 => .{ .float = .{ .type = .f16, .value = null } },
        else => unreachable,
    });
}

fn genVectorType(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const elem_type_node = astgen.tree.nodeLHS(node);
    const elem_type = try astgen.genType(scope, elem_type_node);

    switch (astgen.getInst(elem_type)) {
        .bool, .int, .float => {
            const token_tag = astgen.tree.tokenTag(astgen.tree.nodeToken(node));
            return astgen.addInst(.{
                .vector = .{
                    .size = switch (token_tag) {
                        .k_vec2 => .two,
                        .k_vec3 => .three,
                        .k_vec4 => .four,
                        else => unreachable,
                    },
                    .elem_type = elem_type,
                    .value = null,
                },
            });
        },
        else => {
            try astgen.errors.add(
                astgen.tree.nodeLoc(elem_type_node),
                "invalid vector component type",
                .{},
                try astgen.errors.createNote(
                    null,
                    "must be 'i32', 'u32', 'f32', 'f16' or 'bool'",
                    .{},
                ),
            );
            return error.AnalysisFail;
        },
    }
}

fn genMatrixType(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const elem_type_node = astgen.tree.nodeLHS(node);
    const elem_type = try astgen.genType(scope, elem_type_node);

    switch (astgen.getInst(elem_type)) {
        .bool, .int, .float => {
            const token_tag = astgen.tree.tokenTag(astgen.tree.nodeToken(node));
            return astgen.addInst(.{
                .matrix = .{
                    .cols = matrixCols(token_tag),
                    .rows = matrixRows(token_tag),
                    .elem_type = elem_type,
                    .value = null,
                },
            });
        },
        else => {
            try astgen.errors.add(
                astgen.tree.nodeLoc(elem_type_node),
                "invalid matrix component type",
                .{},
                try astgen.errors.createNote(
                    null,
                    "must be 'f32', or 'f16'",
                    .{},
                ),
            );
            return error.AnalysisFail;
        },
    }
}

fn matrixCols(tag: TokenTag) Air.Inst.Vector.Size {
    return switch (tag) {
        .k_mat2x2, .k_mat2x3, .k_mat2x4 => .two,
        .k_mat3x2, .k_mat3x3, .k_mat3x4 => .three,
        .k_mat4x2, .k_mat4x3, .k_mat4x4 => .four,
        else => unreachable,
    };
}

fn matrixRows(tag: TokenTag) Air.Inst.Vector.Size {
    return switch (tag) {
        .k_mat2x2, .k_mat3x2, .k_mat4x2 => .two,
        .k_mat2x3, .k_mat3x3, .k_mat4x3 => .three,
        .k_mat2x4, .k_mat3x4, .k_mat4x4 => .four,
        else => unreachable,
    };
}

fn genAtomicType(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const elem_type = try astgen.genType(scope, node_lhs);

    if (astgen.getInst(elem_type) == .int) {
        return astgen.addInst(.{ .atomic_type = .{ .elem_type = elem_type } });
    }

    try astgen.errors.add(
        astgen.tree.nodeLoc(node_lhs),
        "invalid atomic component type",
        .{},
        try astgen.errors.createNote(
            null,
            "must be 'i32' or 'u32'",
            .{},
        ),
    );
    return error.AnalysisFail;
}

fn genPtrType(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const elem_type = try astgen.genType(scope, node_lhs);

    switch (astgen.getInst(elem_type)) {
        .bool,
        .int,
        .float,
        .sampler_type,
        .comparison_sampler_type,
        .external_texture_type,
        => {
            const extra = astgen.tree.extraData(Node.PtrType, astgen.tree.nodeRHS(node));

            const addr_space_loc = astgen.tree.tokenLoc(extra.addr_space);
            const ast_addr_space = stringToEnum(Ast.AddressSpace, addr_space_loc.slice(astgen.tree.source)).?;
            const addr_space: Inst.PointerType.AddressSpace = switch (ast_addr_space) {
                .function => .function,
                .private => .private,
                .workgroup => .workgroup,
                .uniform => .uniform,
                .storage => .storage,
            };

            const access_mode_loc = astgen.tree.tokenLoc(extra.access_mode);
            const ast_access_mode = stringToEnum(Ast.AccessMode, access_mode_loc.slice(astgen.tree.source)).?;
            const access_mode: Inst.PointerType.AccessMode = switch (ast_access_mode) {
                .read => .read,
                .write => .write,
                .read_write => .read_write,
            };

            return astgen.addInst(.{
                .ptr_type = .{
                    .elem_type = elem_type,
                    .addr_space = addr_space,
                    .access_mode = access_mode,
                },
            });
        },
        else => {},
    }

    try astgen.errors.add(
        astgen.tree.nodeLoc(node_lhs),
        "invalid pointer component type",
        .{},
        null,
    );
    return error.AnalysisFail;
}

fn genArray(astgen: *AstGen, scope: *Scope, node: NodeIndex, args: ?RefIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    var elem_type = InstIndex.none;
    if (node_lhs != .none) {
        elem_type = try astgen.genType(scope, node_lhs);
        switch (astgen.getInst(elem_type)) {
            .array,
            .atomic_type,
            .@"struct",
            .bool,
            .int,
            .float,
            .vector,
            .matrix,
            => {
                if (astgen.getInst(elem_type) == .array) {
                    if (astgen.getInst(elem_type).array.len == .none) {
                        try astgen.errors.add(
                            astgen.tree.nodeLoc(node_lhs),
                            "array component type can not be a runtime-known array",
                            .{},
                            null,
                        );
                        return error.AnalysisFail;
                    }
                }
            },
            else => {
                try astgen.errors.add(
                    astgen.tree.nodeLoc(node_lhs),
                    "invalid array component type",
                    .{},
                    null,
                );
                return error.AnalysisFail;
            },
        }
    }

    if (args != null) {
        if (args.? == .none) {
            try astgen.errors.add(
                astgen.tree.nodeLoc(node),
                "element type not specified",
                .{},
                null,
            );
            return error.AnalysisFail;
        }

        if (elem_type == .none) {
            elem_type = astgen.refToList(args.?)[0];
        }
    }

    const len_node = astgen.tree.nodeRHS(node);
    var len = InstIndex.none;
    if (len_node != .none) {
        len = try astgen.genExpr(scope, len_node);
    } else if (args != null) {
        len = try astgen.addInst(.{ .int = .{
            .type = .u32,
            .value = try astgen.addValue(Inst.Int.Value, .{ .literal = @intCast(astgen.refToList(args.?).len) }),
        } });
    }

    return astgen.addInst(.{
        .array = .{
            .elem_type = elem_type,
            .len = len,
            .value = args,
        },
    });
}

fn genSamplerType(astgen: *AstGen, node: NodeIndex) !InstIndex {
    const token = astgen.tree.nodeToken(node);
    const token_tag = astgen.tree.tokenTag(token);
    return astgen.addInst(switch (token_tag) {
        .k_sampler => .sampler_type,
        .k_sampler_comparison => .comparison_sampler_type,
        else => unreachable,
    });
}

fn genSampledTextureType(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const elem_type = try astgen.genType(scope, node_lhs);
    const elem_type_inst = astgen.getInst(elem_type);

    if (elem_type_inst == .int or (elem_type_inst == .float and elem_type_inst.float.type == .f32)) {
        const token_tag = astgen.tree.tokenTag(astgen.tree.nodeToken(node));
        return astgen.addInst(.{
            .texture_type = .{
                .kind = switch (token_tag) {
                    .k_texture_1d => .sampled_1d,
                    .k_texture_2d => .sampled_2d,
                    .k_texture_2d_array => .sampled_2d_array,
                    .k_texture_3d => .sampled_3d,
                    .k_texture_cube => .sampled_cube,
                    .k_texture_cube_array => .sampled_cube_array,
                    else => unreachable,
                },
                .elem_type = elem_type,
            },
        });
    }

    try astgen.errors.add(
        astgen.tree.nodeLoc(node_lhs),
        "invalid texture component type",
        .{},
        try astgen.errors.createNote(
            null,
            "must be 'i32', 'u32' or 'f32'",
            .{},
        ),
    );
    return error.AnalysisFail;
}

fn genMultisampledTextureType(astgen: *AstGen, scope: *Scope, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    var elem_type = InstIndex.none;

    if (node_lhs != .none) {
        elem_type = try astgen.genType(scope, node_lhs);
        const elem_type_inst = astgen.getInst(elem_type);

        if (elem_type_inst != .int and !(elem_type_inst == .float and elem_type_inst.float.type == .f32)) {
            try astgen.errors.add(
                astgen.tree.nodeLoc(node_lhs),
                "invalid multisampled texture component type",
                .{},
                try astgen.errors.createNote(
                    null,
                    "must be 'i32', 'u32' or 'f32'",
                    .{},
                ),
            );
            return error.AnalysisFail;
        }
    }

    const token_tag = astgen.tree.tokenTag(astgen.tree.nodeToken(node));
    return astgen.addInst(.{
        .texture_type = .{
            .kind = switch (token_tag) {
                .k_texture_multisampled_2d => .multisampled_2d,
                .k_texture_depth_multisampled_2d => .multisampled_depth_2d,
                else => unreachable,
            },
            .elem_type = elem_type,
        },
    });
}

fn genStorageTextureType(astgen: *AstGen, node: NodeIndex) !InstIndex {
    const node_lhs = astgen.tree.nodeLHS(node);
    const texel_format_loc = astgen.tree.tokenLoc(node_lhs.asTokenIndex());
    const ast_texel_format = stringToEnum(Ast.TexelFormat, texel_format_loc.slice(astgen.tree.source)).?;
    const texel_format: Inst.TextureType.TexelFormat = switch (ast_texel_format) {
        .rgba8unorm => .rgba8unorm,
        .rgba8snorm => .rgba8snorm,
        .rgba8uint => .rgba8uint,
        .rgba8sint => .rgba8sint,
        .rgba16uint => .rgba16uint,
        .rgba16sint => .rgba16sint,
        .rgba16float => .rgba16float,
        .r32uint => .r32uint,
        .r32sint => .r32sint,
        .r32float => .r32float,
        .rg32uint => .rg32uint,
        .rg32sint => .rg32sint,
        .rg32float => .rg32float,
        .rgba32uint => .rgba32uint,
        .rgba32sint => .rgba32sint,
        .rgba32float => .rgba32float,
        .bgra8unorm => .bgra8unorm,
    };

    const node_rhs = astgen.tree.nodeRHS(node);
    const access_mode_loc = astgen.tree.tokenLoc(node_rhs.asTokenIndex());
    const access_mode_full = stringToEnum(Ast.AccessMode, access_mode_loc.slice(astgen.tree.source)).?;
    const access_mode = switch (access_mode_full) {
        .write => Inst.TextureType.AccessMode.write,
        else => {
            try astgen.errors.add(
                access_mode_loc,
                "invalid access mode",
                .{},
                try astgen.errors.createNote(
                    null,
                    "only 'write' is allowed",
                    .{},
                ),
            );
            return error.AnalysisFail;
        },
    };

    const token_tag = astgen.tree.tokenTag(astgen.tree.nodeToken(node));
    const inst = try astgen.addInst(.{
        .texture_type = .{
            .kind = switch (token_tag) {
                .k_texture_storage_1d => .storage_1d,
                .k_texture_storage_2d => .storage_2d,
                .k_texture_storage_2d_array => .storage_2d_array,
                .k_texture_storage_3d => .storage_3d,
                else => unreachable,
            },
            .texel_format = texel_format,
            .access_mode = access_mode,
        },
    });

    return inst;
}

fn genDepthTextureType(astgen: *AstGen, node: NodeIndex) !InstIndex {
    const token_tag = astgen.tree.tokenTag(astgen.tree.nodeToken(node));
    const inst = try astgen.addInst(.{
        .texture_type = .{ .kind = switch (token_tag) {
            .k_texture_depth_2d => .depth_2d,
            .k_texture_depth_2d_array => .depth_2d_array,
            .k_texture_depth_cube => .depth_cube,
            .k_texture_depth_cube_array => .depth_cube_array,
            else => unreachable,
        } },
    });
    return inst;
}

/// takes token and returns the first declaration in the current and parent scopes
fn findSymbol(astgen: *AstGen, scope: *Scope, token: TokenIndex) error{ OutOfMemory, AnalysisFail }!InstIndex {
    std.debug.assert(astgen.tree.tokenTag(token) == .ident);

    const loc = astgen.tree.tokenLoc(token);
    const name = loc.slice(astgen.tree.source);

    var s = scope;
    while (true) {
        var iter = s.decls.iterator();
        while (iter.next()) |decl| {
            const decl_node = decl.key_ptr.*;
            const decl_inst = try decl.value_ptr.*;
            if (std.mem.eql(u8, name, astgen.tree.declNameLoc(decl_node).?.slice(astgen.tree.source))) {
                if (decl_inst == .none) {
                    // declaration has not analysed
                    switch (s.tag) {
                        .root => return astgen.genGlobalDecl(s, decl_node),
                        .@"fn",
                        .block,
                        .loop,
                        .continuing,
                        .switch_case,
                        .@"if",
                        .@"for",
                        => {},
                    }
                } else {
                    return decl_inst;
                }
            }
        }

        if (s.tag == .root) {
            try astgen.errors.add(
                loc,
                "use of undeclared identifier '{s}'",
                .{name},
                null,
            );
            return error.AnalysisFail;
        }

        s = s.parent;
    }
}

fn resolve(astgen: *AstGen, index: InstIndex) !InstIndex {
    var idx = index;

    while (true) {
        const inst = astgen.getInst(idx);
        switch (inst) {
            inline .bool, .int, .float, .vector, .matrix, .array => |data| {
                std.debug.assert(data.value != null);
                return idx;
            },
            .struct_construct => |struct_construct| return struct_construct.@"struct",
            .select => |select| return select.type,
            inline .texture_sample,
            .bitcast,
            .unary,
            .unary_intrinsic,
            .binary,
            .binary_intrinsic,
            .triple_intrinsic,
            .texture_dimension,
            .texture_load,
            => |instruction| return instruction.result_type,

            .call => |call| return astgen.getInst(call.@"fn").@"fn".return_type,
            .var_ref => |var_ref| idx = var_ref,

            .field_access => |field_access| return astgen.getInst(field_access.field).struct_member.type,
            .swizzle_access => |swizzle_access| {
                if (swizzle_access.size == .one) {
                    return swizzle_access.type;
                }
                return astgen.addInst(.{
                    .vector = .{
                        .elem_type = swizzle_access.type,
                        .size = @enumFromInt(@intFromEnum(swizzle_access.size)),
                        .value = null,
                    },
                });
            },
            .index_access => |index_access| return index_access.type,

            inline .@"var", .@"const" => |decl| {
                std.debug.assert(index != idx);

                const decl_type = decl.type;
                const decl_expr = decl.init;
                if (decl_type != .none) return decl_type;
                idx = decl_expr;
            },

            .fn_param => |param| return param.type,

            .nil_intrinsic,
            .texture_store,
            .atomic_type,
            .ptr_type,
            .sampler_type,
            .comparison_sampler_type,
            .external_texture_type,
            .texture_type,
            .@"fn",
            .@"struct",
            .struct_member,
            .block,
            .loop,
            .continuing,
            .@"return",
            .break_if,
            .@"if",
            .@"while",
            .@"for",
            .discard,
            .@"break",
            .@"continue",
            .@"switch",
            .switch_case,
            .assign,
            => unreachable,
        }
    }
}

fn eql(astgen: *AstGen, a_idx: InstIndex, b_idx: InstIndex) bool {
    const a = astgen.getInst(a_idx);
    const b = astgen.getInst(b_idx);

    return switch (a) {
        .int => |int_a| switch (b) {
            .int => |int_b| int_a.type == int_b.type,
            else => false,
        },
        .vector => |vec_a| switch (b) {
            .vector => |vec_b| astgen.eqlVector(vec_a, vec_b),
            else => false,
        },
        .matrix => |mat_a| switch (b) {
            .matrix => |mat_b| astgen.eqlMatrix(mat_a, mat_b),
            else => false,
        },
        else => if (std.meta.activeTag(a) == std.meta.activeTag(b)) true else false,
    };
}

fn eqlVector(astgen: *AstGen, a: Air.Inst.Vector, b: Air.Inst.Vector) bool {
    return a.size == b.size and astgen.eql(a.elem_type, b.elem_type);
}

fn eqlMatrix(astgen: *AstGen, a: Air.Inst.Matrix, b: Air.Inst.Matrix) bool {
    return a.cols == b.cols and a.rows == b.rows and astgen.eql(a.elem_type, b.elem_type);
}

fn addInst(astgen: *AstGen, inst: Inst) error{OutOfMemory}!InstIndex {
    try astgen.instructions.put(astgen.allocator, inst, {});
    return @enumFromInt(astgen.instructions.getIndex(inst).?);
}

fn addRefList(astgen: *AstGen, list: []const InstIndex) error{OutOfMemory}!RefIndex {
    const len = list.len + 1;
    try astgen.refs.ensureUnusedCapacity(astgen.allocator, len);
    astgen.refs.appendSliceAssumeCapacity(list);
    astgen.refs.appendAssumeCapacity(.none);
    return @as(RefIndex, @enumFromInt(astgen.refs.items.len - len));
}

fn addString(astgen: *AstGen, str: []const u8) error{OutOfMemory}!StringIndex {
    const len = str.len + 1;
    try astgen.strings.ensureUnusedCapacity(astgen.allocator, len);
    astgen.strings.appendSliceAssumeCapacity(str);
    astgen.strings.appendAssumeCapacity(0);
    return @enumFromInt(astgen.strings.items.len - len);
}

fn addValue(astgen: *AstGen, comptime T: type, value: T) error{OutOfMemory}!ValueIndex {
    const value_bytes = std.mem.asBytes(&value);
    try astgen.values.appendSlice(astgen.allocator, value_bytes);
    std.testing.expectEqual(value, std.mem.bytesToValue(T, value_bytes)) catch unreachable;
    return @enumFromInt(astgen.values.items.len - value_bytes.len);
}

fn getInst(astgen: *AstGen, inst: InstIndex) Inst {
    return astgen.instructions.entries.slice().items(.key)[@intFromEnum(inst)];
}

fn getValue(astgen: *AstGen, comptime T: type, value: ValueIndex) T {
    return std.mem.bytesAsValue(T, astgen.values.items[@intFromEnum(value)..][0..@sizeOf(T)]).*;
}

fn getStr(astgen: *AstGen, index: StringIndex) []const u8 {
    return std.mem.sliceTo(astgen.strings.items[@intFromEnum(index)..], 0);
}

fn refToList(astgen: *AstGen, ref: RefIndex) []const InstIndex {
    return std.mem.sliceTo(astgen.refs.items[@intFromEnum(ref)..], .none);
}

fn failArgCountMismatch(
    astgen: *AstGen,
    node_loc: Loc,
    expected: usize,
    actual: usize,
) error{ OutOfMemory, AnalysisFail } {
    try astgen.errors.add(
        node_loc,
        "expected {} argument(s), found {}",
        .{ expected, actual },
        null,
    );
    return error.AnalysisFail;
}

const BuiltinFn = enum {
    all,
    any,
    select,
    arrayLength,
    abs,
    acos,
    acosh,
    asin,
    asinh,
    atan,
    atanh,
    atan2,
    ceil,
    clamp,
    cos,
    cosh,
    countLeadingZeros,
    countOneBits,
    countTrailingZeros,
    cross, // unimplemented
    degrees,
    determinant, // unimplemented
    distance,
    dot, // unimplemented
    exp,
    exp2,
    extractBits, // unimplemented
    faceForward, // unimplemented
    firstLeadingBit,
    firstTrailingBit,
    floor,
    fma, // unimplemented
    fract,
    frexp, // unimplemented
    insertBits, // unimplemented
    inverseSqrt,
    ldexp, // unimplemented
    length,
    log,
    log2,
    max,
    min,
    mix,
    modf, // unimplemented
    normalize,
    pow, // unimplemented
    quantizeToF16,
    radians,
    reflect, // unimplemented
    refract, // unimplemented
    reverseBits,
    round,
    saturate,
    sign,
    sin,
    sinh,
    smoothstep,
    sqrt,
    step,
    tan,
    tanh,
    transpose, // unimplemented
    trunc,
    dpdx,
    dpdxCoarse,
    dpdxFine,
    dpdy,
    dpdyCoarse,
    dpdyFine,
    fwidth,
    fwidthCoarse,
    fwidthFine,
    textureDimensions,
    textureGather, // unimplemented
    textureLoad,
    textureNumLayers, // unimplemented
    textureNumLevels, // unimplemented
    textureNumSamples, // unimplemented
    textureSample,
    textureSampleBias, // unimplemented
    textureSampleCompare, // unimplemented
    textureSampleCompareLevel, // unimplemented
    textureSampleGrad, // unimplemented
    textureSampleLevel, // unimplemented
    textureSampleBaseClampToEdge, // unimplemented
    textureStore, // unimplemented
    atomicLoad, // unimplemented
    atomicStore, // unimplemented
    atomicAdd, // unimplemented
    atomicSub, // unimplemented
    atomicMax, // unimplemented
    atomicMin, // unimplemented
    atomicAnd, // unimplemented
    atomicOr, // unimplemented
    atomicXor, // unimplemented
    atomicExchange, // unimplemented
    atomicCompareExchangeWeak, // unimplemented
    pack4x8unorm, // unimplemented
    pack2x16snorm, // unimplemented
    pack2x16unorm, // unimplemented
    pack2x16float, // unimplemented
    unpack4x8snorm, // unimplemented
    unpack4x8unorm, // unimplemented
    unpack2x16snorm, // unimplemented
    unpack2x16unorm, // unimplemented
    unpack2x16float, // unimplemented
    storageBarrier,
    workgroupBarrier,
    workgroupUniformLoad, // unimplemented
};
