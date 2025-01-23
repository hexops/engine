const std = @import("std");

const mach = @import("../main.zig");
const testing = mach.testing;
const math = mach.math;
const mat = @import("mat.zig");
const quat = @import("quat.zig");

pub const VecComponent = enum { x, y, z, w };

pub fn Vec2(comptime Scalar: type) type {
    return extern struct {
        v: Vector,

        /// The vector dimension size, e.g. Vec3.n == 3
        pub const n = 2;

        /// The scalar type of this vector, e.g. Vec3.T == f32
        pub const T = Scalar;

        // The underlying @Vector type
        pub const Vector = @Vector(n, Scalar);

        const VecN = @This();

        const Shared = VecShared(Scalar, VecN);

        pub inline fn init(xs: Scalar, ys: Scalar) VecN {
            return .{ .v = .{ xs, ys } };
        }
        pub inline fn fromInt(xs: anytype, ys: anytype) VecN {
            return .{ .v = .{ @floatFromInt(xs), @floatFromInt(ys) } };
        }
        pub inline fn x(v: *const VecN) Scalar {
            return v.v[0];
        }
        pub inline fn y(v: *const VecN) Scalar {
            return v.v[1];
        }

        pub const add = Shared.add;
        pub const sub = Shared.sub;
        pub const div = Shared.div;
        pub const mul = Shared.mul;
        pub const addScalar = Shared.addScalar;
        pub const subScalar = Shared.subScalar;
        pub const divScalar = Shared.divScalar;
        pub const mulScalar = Shared.mulScalar;
        pub const less = Shared.less;
        pub const lessEq = Shared.lessEq;
        pub const greater = Shared.greater;
        pub const greaterEq = Shared.greaterEq;
        pub const splat = Shared.splat;
        pub const len2 = Shared.len2;
        pub const len = Shared.len;
        pub const normalize = Shared.normalize;
        pub const dir = Shared.dir;
        pub const dist2 = Shared.dist2;
        pub const dist = Shared.dist;
        pub const lerp = Shared.lerp;
        pub const dot = Shared.dot;
        pub const max = Shared.max;
        pub const min = Shared.min;
        pub const inverse = Shared.inverse;
        pub const negate = Shared.negate;
        pub const maxScalar = Shared.maxScalar;
        pub const minScalar = Shared.minScalar;
        pub const eqlApprox = Shared.eqlApprox;
        pub const eql = Shared.eql;
        pub const format = Shared.format;
    };
}

pub fn Vec3(comptime Scalar: type) type {
    return extern struct {
        v: Vector,

        /// The vector dimension size, e.g. Vec3.n == 3
        pub const n = 3;

        /// The scalar type of this vector, e.g. Vec3.T == f32
        pub const T = Scalar;

        // The underlying @Vector type
        pub const Vector = @Vector(n, Scalar);

        const VecN = @This();

        const Shared = VecShared(Scalar, VecN);

        pub inline fn init(xs: Scalar, ys: Scalar, zs: Scalar) VecN {
            return .{ .v = .{ xs, ys, zs } };
        }
        pub inline fn fromInt(xs: anytype, ys: anytype, zs: anytype) VecN {
            return .{ .v = .{ @floatFromInt(xs), @floatFromInt(ys), @floatFromInt(zs) } };
        }
        pub inline fn x(v: *const VecN) Scalar {
            return v.v[0];
        }
        pub inline fn y(v: *const VecN) Scalar {
            return v.v[1];
        }
        pub inline fn z(v: *const VecN) Scalar {
            return v.v[2];
        }

        pub inline fn swizzle(
            v: *const VecN,
            xc: VecComponent,
            yc: VecComponent,
            zc: VecComponent,
        ) VecN {
            return .{ .v = @shuffle(VecN.T, v.v, undefined, [3]T{
                @intFromEnum(xc),
                @intFromEnum(yc),
                @intFromEnum(zc),
            }) };
        }

        /// Calculates the cross product between vector a and b.
        /// This can be done only in 3D and required inputs are Vec3.
        pub inline fn cross(a: *const VecN, b: *const VecN) VecN {
            // https://gamemath.com/book/vectors.html#cross_product
            const s1 = a.swizzle(.y, .z, .x)
                .mul(&b.swizzle(.z, .x, .y));
            const s2 = a.swizzle(.z, .x, .y)
                .mul(&b.swizzle(.y, .z, .x));
            return s1.sub(&s2);
        }

        /// Vector * Matrix multiplication
        pub inline fn mulMat(vector: *const VecN, matrix: *const mat.Mat3x3(T)) VecN {
            var result = [_]VecN.T{0} ** 3;
            inline for (0..3) |i| {
                inline for (0..3) |j| {
                    result[i] += vector.v[j] * matrix.v[i].v[j];
                }
            }
            return .{ .v = result };
        }

        /// Vector * Quat multiplication
        /// https://github.com/greggman/wgpu-matrix/blob/main/src/vec3-impl.ts#L718
        pub inline fn mulQuat(v: *const VecN, q: *const quat.Quat(Scalar)) VecN {
            const qx = q.v.x();
            const qy = q.v.y();
            const qz = q.v.z();
            const w2 = q.v.w() * 2;

            const vx = v.x();
            const vy = v.y();
            const vz = v.z();

            const uv_x = qy * vz - qz * vy;
            const uv_y = qz * vx - qx * vz;
            const uv_z = qx * vy - qy * vx;

            return math.vec3(
                vx + uv_x * w2 + (qy * uv_z - qz * uv_y) * 2,
                vy + uv_y * w2 + (qz * uv_x - qx * uv_z) * 2,
                vz + uv_z * w2 + (qz * uv_y - qy * uv_x) * 2,
            );
        }

        pub const add = Shared.add;
        pub const sub = Shared.sub;
        pub const div = Shared.div;
        pub const mul = Shared.mul;
        pub const addScalar = Shared.addScalar;
        pub const subScalar = Shared.subScalar;
        pub const divScalar = Shared.divScalar;
        pub const mulScalar = Shared.mulScalar;
        pub const less = Shared.less;
        pub const lessEq = Shared.lessEq;
        pub const greater = Shared.greater;
        pub const greaterEq = Shared.greaterEq;
        pub const splat = Shared.splat;
        pub const len2 = Shared.len2;
        pub const len = Shared.len;
        pub const normalize = Shared.normalize;
        pub const dir = Shared.dir;
        pub const dist2 = Shared.dist2;
        pub const dist = Shared.dist;
        pub const lerp = Shared.lerp;
        pub const dot = Shared.dot;
        pub const max = Shared.max;
        pub const min = Shared.min;
        pub const inverse = Shared.inverse;
        pub const negate = Shared.negate;
        pub const maxScalar = Shared.maxScalar;
        pub const minScalar = Shared.minScalar;
        pub const eqlApprox = Shared.eqlApprox;
        pub const eql = Shared.eql;
        pub const format = Shared.format;
    };
}

pub fn Vec4(comptime Scalar: type) type {
    return extern struct {
        v: Vector,

        /// The vector dimension size, e.g. Vec3.n == 3
        pub const n = 4;

        /// The scalar type of this vector, e.g. Vec3.T == f32
        pub const T = Scalar;

        // The underlying @Vector type
        pub const Vector = @Vector(n, Scalar);

        const VecN = @This();

        const Shared = VecShared(Scalar, VecN);

        pub inline fn init(xs: Scalar, ys: Scalar, zs: Scalar, ws: Scalar) VecN {
            return .{ .v = .{ xs, ys, zs, ws } };
        }
        pub inline fn fromInt(xs: anytype, ys: anytype, zs: anytype, ws: anytype) VecN {
            return .{ .v = .{ @floatFromInt(xs), @floatFromInt(ys), @floatFromInt(zs), @floatFromInt(ws) } };
        }
        pub inline fn x(v: *const VecN) Scalar {
            return v.v[0];
        }
        pub inline fn y(v: *const VecN) Scalar {
            return v.v[1];
        }
        pub inline fn z(v: *const VecN) Scalar {
            return v.v[2];
        }
        pub inline fn w(v: *const VecN) Scalar {
            return v.v[3];
        }

        /// Vector * Matrix multiplication
        pub inline fn mulMat(vector: *const VecN, matrix: *const mat.Mat4x4(T)) VecN {
            var result = [_]VecN.T{0} ** 4;
            inline for (0..4) |i| {
                inline for (0..4) |j| {
                    result[i] += vector.v[j] * matrix.v[i].v[j];
                }
            }
            return .{ .v = result };
        }

        pub const add = Shared.add;
        pub const sub = Shared.sub;
        pub const div = Shared.div;
        pub const mul = Shared.mul;
        pub const addScalar = Shared.addScalar;
        pub const subScalar = Shared.subScalar;
        pub const divScalar = Shared.divScalar;
        pub const mulScalar = Shared.mulScalar;
        pub const less = Shared.less;
        pub const lessEq = Shared.lessEq;
        pub const greater = Shared.greater;
        pub const greaterEq = Shared.greaterEq;
        pub const splat = Shared.splat;
        pub const len2 = Shared.len2;
        pub const len = Shared.len;
        pub const normalize = Shared.normalize;
        pub const dir = Shared.dir;
        pub const dist2 = Shared.dist2;
        pub const dist = Shared.dist;
        pub const lerp = Shared.lerp;
        pub const dot = Shared.dot;
        pub const max = Shared.max;
        pub const min = Shared.min;
        pub const inverse = Shared.inverse;
        pub const negate = Shared.negate;
        pub const maxScalar = Shared.maxScalar;
        pub const minScalar = Shared.minScalar;
        pub const eqlApprox = Shared.eqlApprox;
        pub const eql = Shared.eql;
        pub const format = Shared.format;
    };
}

pub fn VecShared(comptime Scalar: type, comptime VecN: type) type {
    return struct {
        /// Element-wise addition
        pub inline fn add(a: *const VecN, b: *const VecN) VecN {
            return .{ .v = a.v + b.v };
        }

        /// Element-wise subtraction
        pub inline fn sub(a: *const VecN, b: *const VecN) VecN {
            return .{ .v = a.v - b.v };
        }

        /// Element-wise division
        pub inline fn div(a: *const VecN, b: *const VecN) VecN {
            return .{ .v = a.v / b.v };
        }

        /// Element-wise multiplication.
        ///
        /// See also .cross()
        pub inline fn mul(a: *const VecN, b: *const VecN) VecN {
            return .{ .v = a.v * b.v };
        }

        /// Scalar addition
        pub inline fn addScalar(a: *const VecN, s: Scalar) VecN {
            return .{ .v = a.v + VecN.splat(s).v };
        }

        /// Scalar subtraction
        pub inline fn subScalar(a: *const VecN, s: Scalar) VecN {
            return .{ .v = a.v - VecN.splat(s).v };
        }

        /// Scalar division
        pub inline fn divScalar(a: *const VecN, s: Scalar) VecN {
            return .{ .v = a.v / VecN.splat(s).v };
        }

        /// Scalar multiplication.
        ///
        /// See .dot() for the dot product
        pub inline fn mulScalar(a: *const VecN, s: Scalar) VecN {
            return .{ .v = a.v * VecN.splat(s).v };
        }

        /// Element-wise a < b
        pub inline fn less(a: *const VecN, b: Scalar) bool {
            return a.v < b.v;
        }

        /// Element-wise a <= b
        pub inline fn lessEq(a: *const VecN, b: Scalar) bool {
            return a.v <= b.v;
        }

        /// Element-wise a > b
        pub inline fn greater(a: *const VecN, b: Scalar) bool {
            return a.v > b.v;
        }

        /// Element-wise a >= b
        pub inline fn greaterEq(a: *const VecN, b: Scalar) bool {
            return a.v >= b.v;
        }

        /// Returns a vector with all components set to the `scalar` value:
        ///
        /// ```
        /// var v = Vec3.splat(1337.0).v;
        /// // v.x == 1337, v.y == 1337, v.z == 1337
        /// ```
        pub inline fn splat(scalar: Scalar) VecN {
            return .{ .v = @splat(scalar) };
        }

        /// Computes the squared length of the vector. Faster than `len()`
        pub inline fn len2(v: *const VecN) Scalar {
            return switch (VecN.n) {
                inline 2 => (v.x() * v.x()) + (v.y() * v.y()),
                inline 3 => (v.x() * v.x()) + (v.y() * v.y()) + (v.z() * v.z()),
                inline 4 => (v.x() * v.x()) + (v.y() * v.y()) + (v.z() * v.z()) + (v.w() * v.w()),
                else => @compileError("Expected Vec2, Vec3, Vec4, found '" ++ @typeName(VecN) ++ "'"),
            };
        }

        /// Computes the length of the vector.
        pub inline fn len(v: *const VecN) Scalar {
            return math.sqrt(len2(v));
        }

        /// Normalizes a vector, such that all components end up in the range [0.0, 1.0].
        ///
        /// d0 is added to the divisor, which means that e.g. if you provide a near-zero value, then in
        /// situations where you would otherwise get NaN back you will instead get a near-zero vector.
        ///
        /// ```
        /// math.vec3(1.0, 2.0, 3.0).normalize(v, 0.00000001);
        /// ```
        pub inline fn normalize(v: *const VecN, d0: Scalar) VecN {
            return v.div(&VecN.splat(v.len() + d0));
        }

        /// Returns the normalized direction vector from points a and b.
        ///
        /// d0 is added to the divisor, which means that e.g. if you provide a near-zero value, then in
        /// situations where you would otherwise get NaN back you will instead get a near-zero vector.
        ///
        /// ```
        /// var v = a_point.dir(b_point, 0.0000001);
        /// ```
        pub inline fn dir(a: *const VecN, b: *const VecN, d0: Scalar) VecN {
            return b.sub(a).normalize(d0);
        }

        /// Calculates the squared distance between points a and b. Faster than `dist()`.
        pub inline fn dist2(a: *const VecN, b: *const VecN) Scalar {
            return b.sub(a).len2();
        }

        /// Calculates the distance between points a and b.
        pub inline fn dist(a: *const VecN, b: *const VecN) Scalar {
            return math.sqrt(a.dist2(b));
        }

        /// Performs linear interpolation between a and b by some amount.
        ///
        /// ```
        /// a.lerp(b, 0.0) == a
        /// a.lerp(b, 1.0) == b
        /// ```
        pub inline fn lerp(a: *const VecN, b: *const VecN, amount: Scalar) VecN {
            return a.mulScalar(1.0 - amount).add(&b.mulScalar(amount));
        }

        /// Calculates the dot product between vector a and b and returns scalar.
        pub inline fn dot(a: *const VecN, b: *const VecN) Scalar {
            return @reduce(.Add, a.v * b.v);
        }

        // Returns a new vector with the max values of two vectors
        pub inline fn max(a: *const VecN, b: *const VecN) VecN {
            return switch (VecN.n) {
                inline 2 => VecN.init(
                    @max(a.x(), b.x()),
                    @max(a.y(), b.y()),
                ),
                inline 3 => VecN.init(
                    @max(a.x(), b.x()),
                    @max(a.y(), b.y()),
                    @max(a.z(), b.z()),
                ),
                inline 4 => VecN.init(
                    @max(a.x(), b.x()),
                    @max(a.y(), b.y()),
                    @max(a.z(), b.z()),
                    @max(a.w(), b.w()),
                ),
                else => @compileError("Expected Vec2, Vec3, Vec4, found '" ++ @typeName(VecN) ++ "'"),
            };
        }

        // Returns a new vector with the min values of two vectors
        pub inline fn min(a: *const VecN, b: *const VecN) VecN {
            return switch (VecN.n) {
                inline 2 => VecN.init(
                    @min(a.x(), b.x()),
                    @min(a.y(), b.y()),
                ),
                inline 3 => VecN.init(
                    @min(a.x(), b.x()),
                    @min(a.y(), b.y()),
                    @min(a.z(), b.z()),
                ),
                inline 4 => VecN.init(
                    @min(a.x(), b.x()),
                    @min(a.y(), b.y()),
                    @min(a.z(), b.z()),
                    @min(a.w(), b.w()),
                ),
                else => @compileError("Expected Vec2, Vec3, Vec4, found '" ++ @typeName(VecN) ++ "'"),
            };
        }

        // Returns the inverse of a given vector
        pub inline fn inverse(a: *const VecN) VecN {
            return switch (VecN.n) {
                inline 2 => .{ .v = (math.vec2(1, 1).v / a.v) },
                inline 3 => .{ .v = (math.vec3(1, 1, 1).v / a.v) },
                inline 4 => .{ .v = (math.vec4(1, 1, 1, 1).v / a.v) },
                else => @compileError("Expected Vec2, Vec3, Vec4, found '" ++ @typeName(VecN) ++ "'"),
            };
        }

        // Negates a given vector
        pub inline fn negate(a: *const VecN) VecN {
            return switch (VecN.n) {
                inline 2 => .{ .v = math.vec2(-1, -1).v * a.v },
                inline 3 => .{ .v = math.vec3(-1, -1, -1).v * a.v },
                inline 4 => .{ .v = math.vec4(-1, -1, -1, -1).v * a.v },
                else => @compileError("Expected Vec2, Vec3, Vec4, found '" ++ @typeName(VecN) ++ "'"),
            };
        }

        // Returns the largest scalar of two vectors
        pub inline fn maxScalar(a: *const VecN, b: *const VecN) Scalar {
            var max_scalar: Scalar = a.v[0];
            inline for (0..VecN.n) |i| {
                if (a.v[i] > max_scalar)
                    max_scalar = a.v[i];
                if (b.v[i] > max_scalar)
                    max_scalar = b.v[i];
            }

            return max_scalar;
        }

        // Returns the smallest scalar of two vectors
        pub inline fn minScalar(a: *const VecN, b: *const VecN) Scalar {
            var min_scalar: Scalar = a.v[0];
            inline for (0..VecN.n) |i| {
                if (a.v[i] < min_scalar)
                    min_scalar = a.v[i];
                if (b.v[i] < min_scalar)
                    min_scalar = b.v[i];
            }

            return min_scalar;
        }

        /// Checks for approximate (absolute tolerance) equality between two vectors
        /// of the same type and dimensions
        pub inline fn eqlApprox(a: *const VecN, b: *const VecN, tolerance: Scalar) bool {
            var i: usize = 0;
            while (i < VecN.n) : (i += 1) {
                if (!math.eql(Scalar, a.v[i], b.v[i], tolerance)) {
                    return false;
                }
            }
            return true;
        }

        /// Checks for approximate (absolute epsilon tolerance) equality
        /// between two vectors of the same type and dimensions
        pub inline fn eql(a: *const VecN, b: *const VecN) bool {
            return a.eqlApprox(b, math.eps(Scalar));
        }

        /// Custom format function for all vector types.
        pub inline fn format(
            self: VecN,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            try std.fmt.formatType(self.v, fmt, options, writer, 1);
        }
    };
}

test "eql_vec2" {
    const a: math.Vec2 = math.vec2(92, 103);
    const b: math.Vec2 = math.vec2(92, 103);
    const c: math.Vec2 = math.vec2(92, 103.2);

    try testing.expect(bool, true).eql(a.eql(&b));
    try testing.expect(bool, false).eql(a.eql(&c));
}

test "eql_vec3" {
    const a: math.Vec3 = math.vec3(92, 103, 576);
    const b: math.Vec3 = math.vec3(92, 103, 576);
    const c: math.Vec3 = math.vec3(92.009, 103.2, 578);

    try testing.expect(bool, true).eql(a.eql(&b));
    try testing.expect(bool, false).eql(a.eql(&c));
}

test "eqlApprox_vec2" {
    const a: math.Vec2 = math.vec2(92.92837, 103.54682);
    const b: math.Vec2 = math.vec2(92.92998, 103.54791);

    try testing.expect(bool, true).eql(a.eqlApprox(&b, 1e-2));
    try testing.expect(bool, false).eql(a.eqlApprox(&b, 1e-3));
}

test "eqlApprox_vec3" {
    const a: math.Vec3 = math.vec3(92.92837, 103.54682, 256.9);
    const b: math.Vec3 = math.vec3(92.92998, 103.54791, 256.9);

    try testing.expect(bool, true).eql(a.eqlApprox(&b, 1e-2));
    try testing.expect(bool, false).eql(a.eqlApprox(&b, 1e-3));
}

test "gpu_compatibility" {
    // https://www.w3.org/TR/WGSL/#alignment-and-size
    try testing.expect(usize, 8).eql(@sizeOf(math.Vec2)); // WGSL AlignOf 8, SizeOf 8
    try testing.expect(usize, 16).eql(@sizeOf(math.Vec3)); // WGSL AlignOf 16, SizeOf 12
    try testing.expect(usize, 16).eql(@sizeOf(math.Vec4)); // WGSL AlignOf 16, SizeOf 16

    try testing.expect(usize, 4).eql(@sizeOf(math.Vec2h)); // WGSL AlignOf 4, SizeOf 4
    try testing.expect(usize, 8).eql(@sizeOf(math.Vec3h)); // WGSL AlignOf 8, SizeOf 6
    try testing.expect(usize, 8).eql(@sizeOf(math.Vec4h)); // WGSL AlignOf 8, SizeOf 8

    try testing.expect(usize, 8 * 2).eql(@sizeOf(math.Vec2d)); // speculative
    try testing.expect(usize, 16 * 2).eql(@sizeOf(math.Vec3d)); // speculative
    try testing.expect(usize, 16 * 2).eql(@sizeOf(math.Vec4d)); // speculative
}

test "zero_struct_overhead" {
    // Proof that using Vec4 is equal to @Vector(4, f32)
    try testing.expect(usize, @alignOf(@Vector(4, f32))).eql(@alignOf(math.Vec4));
    try testing.expect(usize, @sizeOf(@Vector(4, f32))).eql(@sizeOf(math.Vec4));
}

test "dimensions" {
    try testing.expect(usize, 3).eql(math.Vec3.n);
}

test "type" {
    try testing.expect(type, f16).eql(math.Vec3h.T);
}

test "init" {
    try testing.expect(math.Vec3h, math.vec3h(1, 2, 3)).eql(math.vec3h(1, 2, 3));
}

test "splat" {
    try testing.expect(math.Vec3h, math.vec3h(1337, 1337, 1337)).eql(math.Vec3h.splat(1337));
}

test "swizzle_singular" {
    try testing.expect(f32, 1).eql(math.vec3(1, 2, 3).x());
    try testing.expect(f32, 2).eql(math.vec3(1, 2, 3).y());
    try testing.expect(f32, 3).eql(math.vec3(1, 2, 3).z());
}

test "len2" {
    try testing.expect(f32, 2).eql(math.vec2(1, 1).len2());
    try testing.expect(f32, 29).eql(math.vec3(2, 3, -4).len2());
    try testing.expect(f32, 38.115).eqlApprox(math.vec4(1.5, 2.25, 3.33, 4.44).len2(), 0.0001);
    try testing.expect(f32, 0).eql(math.vec4(0, 0, 0, 0).len2());
}

test "len" {
    try testing.expect(f32, 5).eql(math.vec2(3, 4).len());
    try testing.expect(f32, 6).eql(math.vec3(4, 4, 2).len());
    try testing.expect(f32, 6.17373468817700328621).eql(math.vec4(1.5, 2.25, 3.33, 4.44).len());
    try testing.expect(f32, 0).eql(math.vec4(0, 0, 0, 0).len());
}

test "normalize_example" {
    const normalized = math.vec4(10, 0.5, -3, -0.2).normalize(math.eps_f32);
    try testing.expect(math.Vec4, math.vec4(0.95, 0.05, -0.3, -0.02)).eqlApprox(normalized, 0.1);
}

test "normalize_accuracy" {
    const normalized = math.vec2(1, 1).normalize(0);
    const norm_val = math.sqrt1_2; // 1 / sqrt(2)
    try testing.expect(math.Vec2, math.Vec2.splat(norm_val)).eql(normalized);
}

test "normalize_nan" {
    const near_zero = 0.0;
    const normalized = math.vec2(0, 0).normalize(near_zero);
    try testing.expect(bool, true).eql(math.isNan(normalized.x()));
}

test "normalize_no_nan" {
    const near_zero = math.eps_f32;
    const normalized = math.vec2(0, 0).normalize(near_zero);
    try testing.expect(math.Vec2, math.vec2(0, 0)).eqlBinary(normalized);
}

test "max_vec2" {
    const a: math.Vec2 = math.vec2(92, 0);
    const b: math.Vec2 = math.vec2(100, -1);
    try testing.expect(
        math.Vec2,
        math.vec2(100, 0),
    ).eql(math.Vec2.max(&a, &b));
}

test "max_vec3" {
    const a: math.Vec3 = math.vec3(92, 0, -2);
    const b: math.Vec3 = math.vec3(100, -1, -1);
    try testing.expect(
        math.Vec3,
        math.vec3(100, 0, -1),
    ).eql(math.Vec3.max(&a, &b));
}

test "max_vec4" {
    const a: math.Vec4 = math.vec4(92, 0, -2, 5);
    const b: math.Vec4 = math.vec4(100, -1, -1, 3);
    try testing.expect(
        math.Vec4,
        math.vec4(100, 0, -1, 5),
    ).eql(math.Vec4.max(&a, &b));
}

test "min_vec2" {
    const a: math.Vec2 = math.vec2(92, 0);
    const b: math.Vec2 = math.vec2(100, -1);
    try testing.expect(
        math.Vec2,
        math.vec2(92, -1),
    ).eql(math.Vec2.min(&a, &b));
}

test "min_vec3" {
    const a: math.Vec3 = math.vec3(92, 0, -2);
    const b: math.Vec3 = math.vec3(100, -1, -1);
    try testing.expect(
        math.Vec3,
        math.vec3(92, -1, -2),
    ).eql(math.Vec3.min(&a, &b));
}

test "min_vec4" {
    const a: math.Vec4 = math.vec4(92, 0, -2, 5);
    const b: math.Vec4 = math.vec4(100, -1, -1, 3);
    try testing.expect(
        math.Vec4,
        math.vec4(92, -1, -2, 3),
    ).eql(math.Vec4.min(&a, &b));
}

test "inverse_vec2" {
    const a: math.Vec2 = math.vec2(5, 4);
    try testing.expect(
        math.Vec2,
        math.vec2(0.2, 0.25),
    ).eql(math.Vec2.inverse(&a));
}

test "inverse_vec3" {
    const a: math.Vec3 = math.vec3(5, 4, -2);
    try testing.expect(
        math.Vec3,
        math.vec3(0.2, 0.25, -0.5),
    ).eql(math.Vec3.inverse(&a));
}

test "inverse_vec4" {
    const a: math.Vec4 = math.vec4(5, 4, -2, 3);
    try testing.expect(
        math.Vec4,
        math.vec4(0.2, 0.25, -0.5, 0.333333333),
    ).eql(math.Vec4.inverse(&a));
}

test "negate_vec2" {
    const a: math.Vec2 = math.vec2(9, 0.25);
    try testing.expect(
        math.Vec2,
        math.vec2(-9, -0.25),
    ).eql(math.Vec2.negate(&a));
}

test "negate_vec3" {
    const a: math.Vec3 = math.vec3(9, 0.25, 23.8);
    try testing.expect(
        math.Vec3,
        math.vec3(-9, -0.25, -23.8),
    ).eql(math.Vec3.negate(&a));
}

test "negate_vec4" {
    const a: math.Vec4 = math.vec4(9, 0.25, 23.8, -1.2);
    try testing.expect(
        math.Vec4,
        math.vec4(-9, -0.25, -23.8, 1.2),
    ).eql(math.Vec4.negate(&a));
}

test "maxScalar" {
    const a: math.Vec4 = math.vec4(0, 24, -20, 4);
    const b: math.Vec4 = math.vec4(5, -35, 72, 12);
    const c: math.Vec4 = math.vec4(16, 2, 93, -182);

    try testing.expect(f32, 72).eql(math.Vec4.maxScalar(&a, &b));
    try testing.expect(f32, 93).eql(math.Vec4.maxScalar(&b, &c));
}

test "minScalar" {
    const a: math.Vec4 = math.vec4(0, 24, -20, 4);
    const b: math.Vec4 = math.vec4(5, -35, 72, 12);
    const c: math.Vec4 = math.vec4(16, 2, 81, -182);

    try testing.expect(f32, -35).eql(math.Vec4.minScalar(&a, &b));
    try testing.expect(f32, -182).eql(math.Vec4.minScalar(&b, &c));
}

test "add_vec2" {
    const a: math.Vec2 = math.vec2(4, 1);
    const b: math.Vec2 = math.vec2(3, 4);
    try testing.expect(math.Vec2, math.vec2(7, 5)).eql(a.add(&b));
}

test "add_vec3" {
    const a: math.Vec3 = math.vec3(5, 12, 9.2);
    const b: math.Vec3 = math.vec3(7.5, 920, 11);
    try testing.expect(math.Vec3, math.vec3(12.5, 932, 20.2)).eql(a.add(&b));
}

test "add_vec4" {
    const a: math.Vec4 = math.vec4(1280, 910, 926.25, 1000);
    const b: math.Vec4 = math.vec4(20, 1090, 2.25, 2100);
    try testing.expect(math.Vec4, math.vec4(1300, 2000, 928.5, 3100))
        .eql(a.add(&b));
}

test "sub_vec2" {
    const a: math.Vec2 = math.vec2(19, 1);
    const b: math.Vec2 = math.vec2(3, 1);
    try testing.expect(math.Vec2, math.vec2(16, 0)).eql(a.sub(&b));
}

test "sub_vec3" {
    const a: math.Vec3 = math.vec3(7.5, 220, 13);
    const b: math.Vec3 = math.vec3(2, 9, 6);
    try testing.expect(math.Vec3, math.vec3(5.5, 211, 7)).eql(a.sub(&b));
}

test "sub_vec4" {
    const a: math.Vec4 = math.vec4(2023, 7, 2, 7);
    const b: math.Vec4 = math.vec4(-2, -2, -5, -3);
    try testing.expect(math.Vec4, math.vec4(2025, 9, 7, 10))
        .eql(a.sub(&b));
}

test "div_vec2" {
    const a: math.Vec2 = math.vec2(1, 2.8);
    const b: math.Vec2 = math.vec2(2, 4);
    try testing.expect(math.Vec2, math.vec2(0.5, 0.7)).eql(a.div(&b));
}

test "div_vec3" {
    const a: math.Vec3 = math.vec3(21, 144, 1);
    const b: math.Vec3 = math.vec3(3, 12, 3);
    try testing.expect(math.Vec3, math.vec3(7, 12, 0.3333333))
        .eql(a.div(&b));
}

test "div_vec4" {
    const a: math.Vec4 = math.vec4(1024, 512, 29, 3);
    const b: math.Vec4 = math.vec4(2, 2, 2, 10);
    try testing.expect(math.Vec4, math.vec4(512, 256, 14.5, 0.3))
        .eql(a.div(&b));
}

test "mul_vec2" {
    const a: math.Vec2 = math.vec2(29, 900);
    const b: math.Vec2 = math.vec2(29, 2.2);
    try testing.expect(math.Vec2, math.vec2(841, 1980)).eql(a.mul(&b));
}

test "mul_vec3" {
    const a: math.Vec3 = math.vec3(3.72, 9.217, 9);
    const b: math.Vec3 = math.vec3(2.1, 3.3, 9);
    try testing.expect(math.Vec3, math.vec3(7.812, 30.4161, 81))
        .eql(a.mul(&b));
}

test "mul_vec4" {
    const a: math.Vec4 = math.vec4(3.72, 9.217, 9, 21);
    const b: math.Vec4 = math.vec4(2.1, 3.3, 9, 15);
    try testing.expect(math.Vec4, math.vec4(7.812, 30.4161, 81, 315))
        .eql(a.mul(&b));
}

test "addScalar_vec2" {
    const a: math.Vec2 = math.vec2(92, 78);
    const s: f32 = 13;
    try testing.expect(math.Vec2, math.vec2(105, 91))
        .eql(a.addScalar(s));
}

test "addScalar_vec3" {
    const a: math.Vec3 = math.vec3(92, 78, 120);
    const s: f32 = 13;
    try testing.expect(math.Vec3, math.vec3(105, 91, 133))
        .eql(a.addScalar(s));
}

test "addScalar_vec4" {
    const a: math.Vec4 = math.vec4(92, 78, 120, 111);
    const s: f32 = 13;
    try testing.expect(math.Vec4, math.vec4(105, 91, 133, 124))
        .eql(a.addScalar(s));
}

test "subScalar_vec2" {
    const a: math.Vec2 = math.vec2(1000.1, 3);
    const s: f32 = 1;
    try testing.expect(math.Vec2, math.vec2(999.1, 2))
        .eql(a.subScalar(s));
}

test "subScalar_vec3" {
    const a: math.Vec3 = math.vec3(1000.1, 3, 5);
    const s: f32 = 1;
    try testing.expect(math.Vec3, math.vec3(999.1, 2, 4))
        .eql(a.subScalar(s));
}

test "subScalar_vec4" {
    const a: math.Vec4 = math.vec4(1000.1, 3, 5, 38);
    const s: f32 = 1;
    try testing.expect(math.Vec4, math.vec4(999.1, 2, 4, 37))
        .eql(a.subScalar(s));
}

test "divScalar_vec2" {
    const a: math.Vec2 = math.vec2(13, 15);
    const s: f32 = 2;
    try testing.expect(math.Vec2, math.vec2(6.5, 7.5))
        .eql(a.divScalar(s));
}

test "divScalar_vec3" {
    const a: math.Vec3 = math.vec3(13, 15, 12);
    const s: f32 = 2;
    try testing.expect(math.Vec3, math.vec3(6.5, 7.5, 6))
        .eql(a.divScalar(s));
}

test "divScalar_vec4" {
    const a: math.Vec4 = math.vec4(13, 15, 12, 29);
    const s: f32 = 2;
    try testing.expect(math.Vec4, math.vec4(6.5, 7.5, 6, 14.5))
        .eql(a.divScalar(s));
}

test "mulScalar_vec2" {
    const a: math.Vec2 = math.vec2(10, 125);
    const s: f32 = 5;
    try testing.expect(math.Vec2, math.vec2(50, 625))
        .eql(a.mulScalar(s));
}

test "mulScalar_vec3" {
    const a: math.Vec3 = math.vec3(10, 125, 3);
    const s: f32 = 5;
    try testing.expect(math.Vec3, math.vec3(50, 625, 15))
        .eql(a.mulScalar(s));
}

test "mulScalar_vec4" {
    const a: math.Vec4 = math.vec4(10, 125, 3, 27);
    const s: f32 = 5;
    try testing.expect(math.Vec4, math.vec4(50, 625, 15, 135))
        .eql(a.mulScalar(s));
}

test "dir_zero_vec2" {
    const near_zero_value = 1e-8;
    const a: math.Vec2 = math.vec2(0, 0);
    const b: math.Vec2 = math.vec2(0, 0);
    try testing.expect(math.Vec2, math.vec2(0, 0))
        .eql(a.dir(&b, near_zero_value));
}

test "dir_zero_vec3" {
    const near_zero_value = 1e-8;
    const a: math.Vec3 = math.vec3(0, 0, 0);
    const b: math.Vec3 = math.vec3(0, 0, 0);
    try testing.expect(math.Vec3, math.vec3(0, 0, 0))
        .eql(a.dir(&b, near_zero_value));
}

test "dir_zero_vec4" {
    const near_zero_value = 1e-8;
    const a: math.Vec4 = math.vec4(0, 0, 0, 0);
    const b: math.Vec4 = math.vec4(0, 0, 0, 0);
    try testing.expect(math.Vec4, math.vec4(0, 0, 0, 0))
        .eql(a.dir(&b, near_zero_value));
}

test "dir_vec2" {
    const a: math.Vec2 = math.vec2(1, 2);
    const b: math.Vec2 = math.vec2(3, 4);
    try testing.expect(math.Vec2, math.vec2(math.sqrt1_2, math.sqrt1_2))
        .eql(a.dir(&b, 0));
}

test "dir_vec3" {
    const a: math.Vec3 = math.vec3(1, -1, 0);
    const b: math.Vec3 = math.vec3(0, 1, 1);

    const result_x = -0.40824829046386301637; // -1 / sqrt(6)
    const result_y = 0.81649658092772603273; // sqrt(2/3)
    const result_z = -result_x; // 1 / sqrt(6)

    try testing.expect(math.Vec3, math.vec3(result_x, result_y, result_z))
        .eql(a.dir(&b, 0));
}

test "dist_zero_vec2" {
    const a: math.Vec2 = math.vec2(0, 0);
    const b: math.Vec2 = math.vec2(0, 0);
    try testing.expect(f32, 0).eql(a.dist(&b));
}

test "dist_zero_vec3" {
    const a: math.Vec3 = math.vec3(0, 0, 0);
    const b: math.Vec3 = math.vec3(0, 0, 0);
    try testing.expect(f32, 0).eql(a.dist(&b));
}

test "dist_zero_vec4" {
    const a: math.Vec4 = math.vec4(0, 0, 0, 0);
    const b: math.Vec4 = math.vec4(0, 0, 0, 0);
    try testing.expect(f32, 0).eql(a.dist(&b));
}

test "dist_vec2" {
    const a: math.Vec2 = math.vec2(1.5, 2.25);
    const b: math.Vec2 = math.vec2(1.44, -9.33);
    try testing.expect(f64, 11.5802)
        .eqlApprox(a.dist(&b), 1e-4);
}

test "dist_vec3" {
    const a: math.Vec3 = math.vec3(1.5, 2.25, 3.33);
    const b: math.Vec3 = math.vec3(1.44, -9.33, 7.25);
    try testing.expect(f64, 12.2256)
        .eqlApprox(a.dist(&b), 1e-4);
}

test "dist_vec4" {
    const a: math.Vec4 = math.vec4(1.5, 2.25, 3.33, 4.44);
    const b: math.Vec4 = math.vec4(1.44, -9.33, 7.25, -0.5);
    try testing.expect(f64, 13.186)
        .eqlApprox(a.dist(&b), 1e-4);
}

test "dist2_zero_vec2" {
    const a: math.Vec2 = math.vec2(0, 0);
    const b: math.Vec2 = math.vec2(0, 0);
    try testing.expect(f32, 0).eql(a.dist2(&b));
}

test "dist2_zero_vec3" {
    const a: math.Vec3 = math.vec3(0, 0, 0);
    const b: math.Vec3 = math.vec3(0, 0, 0);
    try testing.expect(f32, 0).eql(a.dist2(&b));
}

test "dist2_zero_vec4" {
    const a: math.Vec4 = math.vec4(0, 0, 0, 0);
    const b: math.Vec4 = math.vec4(0, 0, 0, 0);
    try testing.expect(f32, 0).eql(a.dist2(&b));
}

test "dist2_vec2" {
    const a: math.Vec2 = math.vec2(1.5, 2.25);
    const b: math.Vec2 = math.vec2(1.44, -9.33);
    try testing.expect(f64, 134.10103204).eqlApprox(a.dist2(&b), 1e-2);
}

test "dist2_vec3" {
    const a: math.Vec3 = math.vec3(1.5, 2.25, 3.33);
    const b: math.Vec3 = math.vec3(1.44, -9.33, 7.25);
    try testing.expect(f64, 149.46529536).eqlApprox(a.dist2(&b), 1e-2);
}

test "dist2_vec4" {
    const a: math.Vec4 = math.vec4(1.5, 2.25, 3.33, 4.44);
    const b: math.Vec4 = math.vec4(1.44, -9.33, 7.25, -0.5);
    try testing.expect(f64, 173.870596).eqlApprox(a.dist2(&b), 1e-3);
}

test "lerp_zero_vec2" {
    const a: math.Vec2 = math.vec2(1, 1);
    const b: math.Vec2 = math.vec2(0, 0);
    try testing.expect(math.Vec2, math.vec2(1, 1)).eql(a.lerp(&b, 0));
}

test "lerp_zero_vec3" {
    const a: math.Vec3 = math.vec3(1, 1, 1);
    const b: math.Vec3 = math.vec3(0, 0, 0);
    try testing.expect(math.Vec3, math.vec3(1, 1, 1)).eql(a.lerp(&b, 0));
}

test "lerp_zero_vec4" {
    const a: math.Vec4 = math.vec4(1, 1, 1, 1);
    const b: math.Vec4 = math.vec4(0, 0, 0, 0);
    try testing.expect(math.Vec4, math.vec4(1, 1, 1, 1)).eql(a.lerp(&b, 0));
}

test "cross" {
    const a: math.Vec3 = math.vec3(1, 3, 4);
    const b: math.Vec3 = math.vec3(2, -5, 8);
    try testing.expect(math.Vec3, math.vec3(44, 0, -11))
        .eql(a.cross(&b));

    const c: math.Vec3 = math.vec3(1.0, 0.0, 0.0);
    const d: math.Vec3 = math.vec3(0.0, 1.0, 0.0);
    try testing.expect(math.Vec3, math.vec3(0.0, 0.0, 1.0))
        .eql(c.cross(&d));

    const e: math.Vec3 = math.vec3(-3.0, 0.0, -2.0);
    const f: math.Vec3 = math.vec3(5.0, -1.0, 2.0);
    try testing.expect(math.Vec3, math.vec3(-2.0, -4.0, 3.0))
        .eql(e.cross(&f));
}

test "dot_vec2" {
    const a: math.Vec2 = math.vec2(-1, 2);
    const b: math.Vec2 = math.vec2(4, 5);
    try testing.expect(f32, 6).eql(a.dot(&b));
}

test "dot_vec3" {
    const a: math.Vec3 = math.vec3(-1, 2, 3);
    const b: math.Vec3 = math.vec3(4, 5, 6);
    try testing.expect(f32, 24).eql(a.dot(&b));
}

test "dot_vec4" {
    const a: math.Vec4 = math.vec4(-1, 2, 3, -2);
    const b: math.Vec4 = math.vec4(4, 5, 6, 2);
    try testing.expect(f32, 20).eql(a.dot(&b));
}

test "Mat3x3_mulMat" {
    const matrix = math.Mat3x3.init(
        &math.vec3(2, 2, 2),
        &math.vec3(3, 4, 3),
        &math.vec3(1, 1, 2),
    );
    const v = math.vec3(1, 2, 0);

    const m = math.Vec3.mulMat(&v, &matrix);
    const expected = math.vec3(8, 10, 8);
    try testing.expect(math.Vec3, expected).eql(m);
}

test "Mat4x4_mulMat" {
    const matrix = math.Mat4x4.init(
        &math.vec4(2, 2, 2, 1),
        &math.vec4(3, 4, 3, 0),
        &math.vec4(1, 1, 2, 2),
        &math.vec4(1, 1, 2, 2),
    );
    const v = math.vec4(1, 2, 0, -1);

    const m = math.Vec4.mulMat(&v, &matrix);
    const expected = math.vec4(7, 9, 6, -1);
    try testing.expect(math.Vec4, expected).eql(m);
}

test "mulQuat" {
    const up = math.vec3(0, 1, 0);
    const id = math.Quat.identity();
    const rot = math.Quat.rotateZ(&id, -math.pi / 2.0);
    try testing.expect(math.Vec3, math.vec3(1, 0, 0)).eql(up.mulQuat(&rot));
}

test "Vec2_fromInt" {
    const x: i8 = 0;
    const y: i32 = 1;
    const v = math.vec2FromInt(x, y);
    const expected = math.vec2(0, 1);
    try testing.expect(math.Vec2, expected).eql(v);
}

test "Vec3_fromInt" {
    const x: i8 = 0;
    const y: i32 = 1;
    const z: i64 = 2;
    const v = math.vec3FromInt(x, y, z);
    const expected = math.vec3(0, 1, 2);
    try testing.expect(math.Vec3, expected).eql(v);
}

test "Vec4_fromInt" {
    const x: i8 = 0;
    const y: i32 = 1;
    const z: i64 = 2;
    const w: i128 = 3;
    const v = math.vec4FromInt(x, y, z, w);
    const expected = math.vec4(0, 1, 2, 3);
    try testing.expect(math.Vec4, expected).eql(v);
}

test "Vec4d_fromInt" {
    const x: i8 = 0;
    const y: i32 = 1;
    const z: i64 = 2;
    const w: i128 = 3;
    const v = math.vec4dFromInt(x, y, z, w);
    const expected = math.vec4d(0, 1, 2, 3);
    try testing.expect(math.Vec4d, expected).eql(v);
}
