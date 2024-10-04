const std = @import("std");
const testing = std.testing;

const mach = @import("main.zig");
const math = mach.math;

fn ExpectFloat(comptime T: type) type {
    return struct {
        expected: T,

        /// Approximate (absolute epsilon tolerance) equality
        pub fn eql(e: *const @This(), actual: T) !void {
            try e.eqlApprox(actual, math.eps(T));
        }

        /// Approximate (absolute tolerance) equality
        pub fn eqlApprox(e: *const @This(), actual: T, tolerance: T) !void {
            // Note: testing.expectApproxEqAbs does the same thing, but does not print floating
            // point values as decimal (prefers scientific notation)
            if (!math.eql(T, e.expected, actual, tolerance)) {
                std.debug.print("actual float {d}, expected {d} (not within absolute epsilon tolerance {d})\n", .{ actual, e.expected, tolerance });
                return error.TestExpectEqualEps;
            }
        }

        /// Bitwise equality
        pub fn eqlBinary(e: *const @This(), actual: T) !void {
            try testing.expectEqual(e.expected, actual);
        }
    };
}

fn ExpectVector(comptime T: type) type {
    const Elem = std.meta.Elem(T);
    const len = @typeInfo(T).vector.len;
    return struct {
        expected: T,

        /// Approximate (absolute epsilon tolerance) equality
        pub fn eql(e: *const @This(), actual: T) !void {
            try e.eqlApprox(actual, math.eps(Elem));
        }

        /// Approximate (absolute tolerance) equality
        pub fn eqlApprox(e: *const @This(), actual: T, tolerance: Elem) !void {
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (!math.eql(Elem, e.expected[i], actual[i], tolerance)) {
                    std.debug.print("actual vector {d}, expected {d} (not within absolute epsilon tolerance {d})\n", .{ actual, e.expected, tolerance });
                    std.debug.print("actual vector[{}] = {d}, expected {d} (not within absolute epsilon tolerance {d})\n", .{ i, actual[i], e.expected[i], tolerance });
                    return error.TestExpectEqualEps;
                }
            }
        }

        /// Bitwise equality
        pub fn eqlBinary(e: *const @This(), actual: T) !void {
            try testing.expectEqual(e.expected, actual);
        }
    };
}

fn ExpectVecMat(comptime T: type) type {
    return struct {
        expected: T,

        /// Approximate (absolute epsilon tolerance) equality
        pub fn eql(e: *const @This(), actual: T) !void {
            try e.eqlApprox(actual, math.eps(T.T));
        }

        /// Approximate (absolute tolerance) equality
        pub fn eqlApprox(e: *const @This(), actual: T, tolerance: T.T) !void {
            var i: usize = 0;
            while (i < T.n) : (i += 1) {
                if (!math.eql(T.T, e.expected.v[i], actual.v[i], tolerance)) {
                    std.debug.print("actual vector {d}, expected {d} (not within absolute epsilon tolerance {d})\n", .{ actual.v, e.expected.v, tolerance });
                    std.debug.print("actual vector[{}] = {d}, expected {d} (not within absolute epsilon tolerance {d})\n", .{ i, actual.v[i], e.expected.v[i], tolerance });
                    return error.TestExpectEqualEps;
                }
            }
        }

        /// Bitwise equality
        pub fn eqlBinary(e: *const @This(), actual: T) !void {
            try testing.expectEqual(e.expected.v, actual.v);
        }
    };
}

fn ExpectComptime(comptime T: type) type {
    return struct {
        expected: T,
        pub fn eql(e: *const @This(), actual: T) !void {
            try testing.expectEqual(e.expected, actual);
        }
    };
}

fn ExpectBytes(comptime T: type) type {
    return struct {
        expected: T,

        pub fn eql(e: *const @This(), actual: T) !void {
            try testing.expectEqualStrings(e.expected, actual);
        }

        pub fn eqlBinary(e: *const @This(), actual: T) !void {
            try testing.expectEqual(e.expected, actual);
        }
    };
}

fn Expect(comptime T: type) type {
    if (T == type) return ExpectComptime(T);
    if (T == f16 or T == f32 or T == f64) return ExpectFloat(T);
    if (T == []const u8) return ExpectBytes(T);
    if (@typeInfo(T) == .vector) return ExpectVector(T);

    // Vector and matrix equality
    const is_vec2 = T == math.Vec2 or T == math.Vec2h or T == math.Vec2d;
    const is_vec3 = T == math.Vec3 or T == math.Vec3h or T == math.Vec3d;
    const is_vec4 = T == math.Vec4 or T == math.Vec4h or T == math.Vec4d;
    if (is_vec2 or is_vec3 or is_vec4) return ExpectVecMat(T);

    // TODO(testing): TODO(math): handle Mat, []Vec, []Mat without generic equality below.
    // We can look at how std.testing handles slices, e.g. we should have equal or better output than
    // what generic equality below gets us:
    //
    // ```
    // ============ expected this output: =============  len: 4 (0x4)
    //
    // [0]: math.vec.Vec(4,f32){ .v = { 1.0e+00, 0.0e+00, 0.0e+00, 0.0e+00 } }
    // [1]: math.vec.Vec(4,f32){ .v = { 0.0e+00, 1.0e+00, 0.0e+00, 0.0e+00 } }
    // [2]: math.vec.Vec(4,f32){ .v = { 0.0e+00, 0.0e+00, 1.0e+00, 0.0e+00 } }
    // [3]: math.vec.Vec(4,f32){ .v = { 0.0e+00, 0.0e+00, 0.0e+00, 1.0e+00 } }
    //
    // ============= instead found this: ==============  len: 4 (0x4)
    //
    // [0]: math.vec.Vec(4,f32){ .v = { 1.0e+00, 0.0e+00, 0.0e+00, 0.0e+00 } }
    // [1]: math.vec.Vec(4,f32){ .v = { 0.0e+00, 1.0e+00, 0.0e+00, 0.0e+00 } }
    // [2]: math.vec.Vec(4,f32){ .v = { 0.0e+00, 0.0e+00, 1.0e+00, 0.0e+00 } }
    // [3]: math.vec.Vec(4,f32){ .v = { 0.0e+00, 0.0e+00, 1.0e+00, 1.0e+00 } }
    // ```
    //

    // Generic equality
    return struct {
        expected: T,
        pub fn eql(e: *const @This(), actual: T) !void {
            try testing.expectEqual(e.expected, actual);
        }
    };
}

/// Alternative to std.testing equality methods with:
///
/// * Less ambiguity about order of parameters
/// * Approximate absolute float equality by default
/// * Handling of vector and matrix types
///
/// Floats, mach.math.Vec, and mach.math.Mat types support:
///
/// * `.eql(v)` (epsilon equality)
/// * `.eqlApprox(v, tolerance)` (specific tolerance equality)
/// * `.eqlBinary(v)` binary equality
///
/// All other types support only `.eql(v)` binary equality.
///
/// Comparisons with std.testing:
///
/// ```diff
/// -std.testing.expectEqual(@as(u32, 1337), actual())
/// +mach.testing.expect(u32, 1337).eql(actual())
/// ```
///
/// ```diff
/// -std.testing.expectApproxEqAbs(@as(f32, 1.0), actual(), std.math.floatEps(f32))
/// +mach.testing.expect(f32, 1.0).eql(actual())
/// ```
///
/// ```diff
/// -std.testing.expectApproxEqAbs(@as(f32, 1.0), actual(), 0.1)
/// +mach.testing.expect(f32, 1.0).eqlApprox(actual(), 0.1)
/// ```
///
/// ```diff
/// -std.testing.expectEqual(@as(f32, 1.0), actual())
/// +mach.testing.expect(f32, 1.0).eqlBinary(actual())
/// ```
///
/// ```diff
/// -std.testing.expectEqual(@as([]const u8, byte_array), actual())
/// +mach.testing.expect([]const u8, byte_array).eqlBinary(actual())
/// ```
///
/// ```diff
/// -std.testing.expectEqualStrings("foo", actual())
/// +mach.testing.expect([]const u8, "foo").eql(actual())
/// ```
///
/// Note that std.testing cannot handle @Vector approximate equality at all, while mach.testing uses
/// approx equality of mach.Vec and mach.Mat by default.
pub fn expect(comptime T: type, expected: T) Expect(T) {
    return Expect(T){ .expected = expected };
}

pub const allocator = testing.allocator;
pub const refAllDeclsRecursive = testing.refAllDeclsRecursive;

test {
    refAllDeclsRecursive(Expect(u32));
    refAllDeclsRecursive(Expect(f32));
    refAllDeclsRecursive(Expect([]const u8));
    refAllDeclsRecursive(Expect(@Vector(3, f32)));
    refAllDeclsRecursive(Expect(mach.math.Vec2h));
    refAllDeclsRecursive(Expect(mach.math.Vec3));
    refAllDeclsRecursive(Expect(mach.math.Vec4d));
    refAllDeclsRecursive(Expect(mach.math.Ray));
    // refAllDeclsRecursive(Expect(mach.math.Mat4h));
    // refAllDeclsRecursive(Expect(mach.math.Mat4));
    // refAllDeclsRecursive(Expect(mach.math.Mat4d));
}
