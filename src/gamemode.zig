const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.gamemode);

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const LoadError = error{MissingSymbol} || std.DynLib.Error;
pub const Error = error{ RequestFailed, RequestRejected };

pub const Status = enum(u8) {
    inactive = 0,
    active = 1,
    active_and_registered = 2,

    pub fn isActive(self: Status) bool {
        const lut = [_]bool{ false, true, true };
        return lut[@intFromEnum(self)];
    }
};

pub const advanced = switch (builtin.os.tag) {
    .linux => linux_impl,
    else => noop_impl,
};

test "start and end gamemode" {
    try std.testing.expectEqual(false, isActive());
    start();
    stop();
    try std.testing.expectEqual(false, isActive());
}

pub fn start() void {
    if (!advanced.init()) return;
    advanced.requestStart() catch |err| {
        log.warn("gamemode: failed to start: {}", .{err});
    };
}

pub fn isActive() bool {
    const status = advanced.queryStatus() catch |err| {
        log.warn("gamemode: error querying status: {}", .{err});
        return false;
    };
    return status.isActive();
}

pub fn stop() void {
    advanced.requestEnd() catch |err| {
        log.warn("gamemode: failed to end: {}", .{err});
    };
    advanced.deinit();
}

const linux_impl = struct {
    comptime {
        if (!builtin.link_libc) {
            // TODO: LibC is currently required for using `dlopen`.
            // We might get it working using Zig's `ElfDynLib` later, but this would require
            // finding the location of the gamemode lib somehow. It also wouldn't be 100% correct,
            // as `LD_PRELOAD` wouldn't be respected.
            @compileError("Must link LibC for gamemode!");
        }
    }

    /// Global state for the library handle
    var state: State = .uninit;

    const State = union(enum) {
        uninit,
        failed,
        init: GamemodeHandle,
    };

    const GamemodeHandle = struct {
        lib: std.DynLib,
        syms: SymbolTable,
    };

    const SymbolTable = struct {
        real_gamemode_error_string: *const fn () callconv(.C) [*:0]const u8,

        real_gamemode_request_start: *const fn () callconv(.C) c_int,
        real_gamemode_request_end: *const fn () callconv(.C) c_int,
        real_gamemode_query_status: *const fn () callconv(.C) c_int,

        real_gamemode_request_start_for: *const fn (std.c.pid_t) callconv(.C) c_int,
        real_gamemode_request_end_for: *const fn (std.c.pid_t) callconv(.C) c_int,
        real_gamemode_query_status_for: *const fn (std.c.pid_t) callconv(.C) c_int,
    };

    /// Try to load libgamemode, returning an error when loading fails.
    /// If you want to ignore errors, call `init` instead.
    ///
    /// Unlike `init`, calling `init` or `tryInit` after a failure
    /// will attempt to load libgamemode again.
    pub fn tryInit() LoadError!void {
        if (state == .init) return;

        var dl = std.DynLib.open("libgamemode.so.0") catch |e| switch (e) {
            // backwards-compatibility for old gamemode versions
            error.FileNotFound => try std.DynLib.open("libgamemode.so"),
            else => return e,
        };
        errdefer dl.close();

        // Populate symbol table.
        var sym_table: SymbolTable = undefined;
        inline for (@typeInfo(SymbolTable).@"struct".fields) |field| {
            @field(sym_table, field.name) = dl.lookup(field.type, field.name ++ &[_:0]u8{}) orelse {
                log.err("libgamemode missing symbol '{s}'", .{field.name});
                return error.MissingSymbol;
            };
        }

        state = State{ .init = .{ .lib = dl, .syms = sym_table } };
    }

    /// Initialize gamemode, logging a possible failure.
    /// If this fails, no more attempts at loading libgamemode will be made.
    /// Returns true if gamemode is initialized.
    pub fn init() bool {
        switch (state) {
            .init => return true,
            .failed => return false,
            .uninit => {
                tryInit() catch |e| {
                    if (e != error.FileNotFound) {
                        log.warn("Loading gamemode: '{}'. Disabling libgamemode support.", .{e});
                    }
                    state = .failed;
                    return false;
                };
                return true;
            },
        }
    }

    /// Deinitializes gamemode.
    pub fn deinit() void {
        switch (state) {
            .init => |*handle| {
                handle.lib.close();
                state = .uninit;
            },
            else => {},
        }
    }

    /// Returns true if libgamemode has been initialized, false otherwise.
    pub fn isInit() bool {
        return state == .init;
    }

    /// Query the status of gamemode.
    /// This does blocking IO!
    pub fn queryStatus() Error!Status {
        if (!init()) return .inactive;

        const ret = state.init.syms.real_gamemode_query_status();
        if (ret < 0)
            return error.RequestFailed;

        return @as(Status, @enumFromInt(ret));
    }

    /// Query the status of gamemode for a given PID.
    /// This does blocking IO!
    pub fn queryStatusFor(pid: std.c.pid_t) Error!Status {
        if (!init()) return .inactive;

        const ret = state.init.syms.real_gamemode_query_status_for(pid);
        return switch (ret) {
            -1 => error.RequestFailed,
            -2 => error.RequestRejected,
            else => @as(Status, @enumFromInt(ret)),
        };
    }

    /// Request starting gamemode.
    /// This does blocking IO!
    pub fn requestStart() Error!void {
        if (!init()) return;

        const ret = state.init.syms.real_gamemode_request_start();
        if (ret < 0)
            return error.RequestFailed;
    }

    /// Request starting gamemode for a given PID.
    /// This does blocking IO!
    pub fn requestStartFor(pid: std.c.pid_t) Error!void {
        if (!init()) return;

        const ret = state.init.syms.real_gamemode_request_start_for(pid);
        return switch (ret) {
            -1 => error.RequestFailed,
            -2 => error.RequestRejected,
            else => {},
        };
    }

    /// Request stopping gamemode.
    /// This does blocking IO!
    pub fn requestEnd() Error!void {
        if (!init()) return;

        const ret = state.init.syms.real_gamemode_request_end();
        if (ret < 0)
            return error.RequestFailed;
    }

    /// Request stopping gamemode for a given PID.
    /// This does blocking IO!
    pub fn requestEndFor(pid: std.c.pid_t) Error!void {
        if (!init()) return;

        const ret = state.init.syms.real_gamemode_request_end_for(pid);
        return switch (ret) {
            -1 => error.RequestFailed,
            -2 => error.RequestRejected,
            else => {},
        };
    }
};

const noop_impl = struct {
    pub fn tryInit() LoadError!void {}

    pub fn init() bool {
        return false;
    }

    pub fn deinit() void {}

    pub fn isInit() bool {
        return false;
    }

    pub fn queryStatus() Error!Status {
        return .inactive;
    }

    pub fn queryStatusFor(pid: std.c.pid_t) Error!Status {
        _ = pid;
        return .inactive;
    }

    pub fn requestStart() Error!void {}

    pub fn requestStartFor(pid: std.c.pid_t) Error!void {
        _ = pid;
    }

    pub fn requestEnd() Error!void {}

    pub fn requestEndFor(pid: std.c.pid_t) Error!void {
        _ = pid;
    }
};
