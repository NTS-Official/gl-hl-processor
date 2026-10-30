const std = @import("std");

pub const Scalar = enum {
    bool,
    int,
    uint,
    float,
    double,

    pub fn hlsl(self: Scalar) []const u8 {
        return switch (self) {
            .bool => "bool",
            .int => "int",
            .uint => "uint",
            .float => "float",
            .double => "double",
        };
    }
};

pub const SamplerKind = enum {
    sampler1D,
    sampler2D,
    sampler3D,
    samplerCube,
    sampler2DArray,
    samplerCubeArray,
    samplerBuffer,
    sampler1DArray,
    sampler1DShadow,
    sampler2DShadow,
    samplerCubeShadow,
    sampler2DArrayShadow,
    sampler1DArrayShadow,
    isampler1D,
    isampler2D,
    isampler3D,
    isamplerCube,
    isampler2DArray,
    isamplerBuffer,
    usampler1D,
    usampler2D,
    usampler3D,
    usamplerCube,
    usampler2DArray,
    usamplerBuffer,

    pub fn baseScalar(self: SamplerKind) Scalar {
        return switch (self) {
            .isampler1D, .isampler2D, .isampler3D, .isamplerCube, .isampler2DArray, .isamplerBuffer => .int,
            .usampler1D, .usampler2D, .usampler3D, .usamplerCube, .usampler2DArray, .usamplerBuffer => .uint,
            else => .float,
        };
    }

    pub fn isShadow(self: SamplerKind) bool {
        return switch (self) {
            .sampler1DShadow, .sampler2DShadow, .samplerCubeShadow, .sampler2DArrayShadow, .sampler1DArrayShadow => true,
            else => false,
        };
    }

    pub fn coordDims(self: SamplerKind) u8 {
        return switch (self) {
            .sampler1D, .samplerBuffer, .isampler1D, .usampler1D, .isamplerBuffer, .usamplerBuffer, .sampler1DShadow, .sampler1DArray, .sampler1DArrayShadow => 1,
            .sampler2D, .sampler2DArray, .isampler2D, .isampler2DArray, .usampler2D, .usampler2DArray, .sampler2DShadow, .sampler2DArrayShadow => 2,
            .sampler3D, .isampler3D, .usampler3D => 3,
            .samplerCube, .samplerCubeArray, .samplerCubeShadow, .isamplerCube, .usamplerCube => 3,
        };
    }

    pub fn isArray(self: SamplerKind) bool {
        return switch (self) {
            .sampler2DArray,
            .samplerCubeArray,
            .sampler1DArray,
            .sampler1DArrayShadow,
            .sampler2DArrayShadow,
            .isampler2DArray,
            .usampler2DArray,
            => true,
            else => false,
        };
    }

    pub fn isBuffer(self: SamplerKind) bool {
        return switch (self) {
            .samplerBuffer, .isamplerBuffer, .usamplerBuffer => true,
            else => false,
        };
    }
};

pub const Type = union(enum) {
    void_,
    scalar: Scalar,
    vector: Vector,
    matrix: Matrix,
    sampler: SamplerKind,
    array: Array,
    named: []const u8,
    unknown,

    pub const Vector = struct {
        scalar: Scalar,
        len: u8,
    };

    pub const Matrix = struct {
        cols: u8,
        rows: u8,
    };

    pub const Array = struct {
        elem: *const Type,
        len: ?u32,
    };

    pub fn isVoid(self: Type) bool {
        return switch (self) {
            .void_ => true,
            else => false,
        };
    }

    pub fn isScalar(self: Type) bool {
        return switch (self) {
            .scalar => true,
            else => false,
        };
    }

    pub fn isVector(self: Type) bool {
        return switch (self) {
            .vector => true,
            else => false,
        };
    }

    pub fn isMatrix(self: Type) bool {
        return switch (self) {
            .matrix => true,
            else => false,
        };
    }

    pub fn isSampler(self: Type) bool {
        return switch (self) {
            .sampler => true,
            else => false,
        };
    }

    pub fn scalarOf(self: Type) ?Scalar {
        return switch (self) {
            .scalar => |s| s,
            .vector => |v| v.scalar,
            .matrix => .float,
            else => null,
        };
    }

    pub fn componentCount(self: Type) ?u8 {
        return switch (self) {
            .scalar => 1,
            .vector => |v| v.len,
            else => null,
        };
    }
};

pub fn same(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .void_ => true,
        .unknown => true,
        .scalar => |s| s == b.scalar,
        .vector => |v| v.scalar == b.vector.scalar and v.len == b.vector.len,
        .matrix => |m| m.cols == b.matrix.cols and m.rows == b.matrix.rows,
        .sampler => |s| s == b.sampler,
        .named => |n| std.mem.eql(u8, n, b.named),
        .array => |x| x.len == b.array.len and same(x.elem.*, b.array.elem.*),
    };
}

pub fn hlslName(allocator: std.mem.Allocator, typ: Type) ![]const u8 {
    return switch (typ) {
        .void_ => "void",
        .unknown => "unknown",
        .scalar => |s| s.hlsl(),
        .vector => |v| std.fmt.allocPrint(allocator, "{s}{d}", .{ v.scalar.hlsl(), v.len }),
        .matrix => |m| std.fmt.allocPrint(allocator, "float{d}x{d}", .{ m.rows, m.cols }),
        .sampler => |s| samplerHlsl(s),
        .named => |n| n,
        .array => |a| try hlslName(allocator, a.elem.*),
    };
}

fn samplerHlsl(kind: SamplerKind) []const u8 {
    if (kind.isBuffer()) return "Buffer";
    return switch (kind) {
        .sampler1D, .sampler1DShadow, .sampler1DArray, .sampler1DArrayShadow => "Texture1D",
        .sampler2D, .sampler2DShadow, .sampler2DArray, .sampler2DArrayShadow => "Texture2D",
        .sampler3D => "Texture3D",
        .samplerCube, .samplerCubeShadow, .samplerCubeArray => "TextureCube",
        .isampler1D, .usampler1D => "Texture1D",
        .isampler2D, .usampler2D, .isampler2DArray, .usampler2DArray => "Texture2D",
        .isampler3D, .usampler3D => "Texture3D",
        .isamplerCube, .usamplerCube => "TextureCube",
        else => "Texture2D",
    };
}

const sampler_names = [_]struct { name: []const u8, kind: SamplerKind }{
    .{ .name = "sampler1D", .kind = .sampler1D },
    .{ .name = "sampler2D", .kind = .sampler2D },
    .{ .name = "sampler3D", .kind = .sampler3D },
    .{ .name = "samplerCube", .kind = .samplerCube },
    .{ .name = "sampler2DArray", .kind = .sampler2DArray },
    .{ .name = "samplerCubeArray", .kind = .samplerCubeArray },
    .{ .name = "samplerBuffer", .kind = .samplerBuffer },
    .{ .name = "sampler1DArray", .kind = .sampler1DArray },
    .{ .name = "sampler1DShadow", .kind = .sampler1DShadow },
    .{ .name = "sampler2DShadow", .kind = .sampler2DShadow },
    .{ .name = "samplerCubeShadow", .kind = .samplerCubeShadow },
    .{ .name = "sampler2DArrayShadow", .kind = .sampler2DArrayShadow },
    .{ .name = "sampler1DArrayShadow", .kind = .sampler1DArrayShadow },
    .{ .name = "isampler1D", .kind = .isampler1D },
    .{ .name = "isampler2D", .kind = .isampler2D },
    .{ .name = "isampler3D", .kind = .isampler3D },
    .{ .name = "isamplerCube", .kind = .isamplerCube },
    .{ .name = "isampler2DArray", .kind = .isampler2DArray },
    .{ .name = "isamplerBuffer", .kind = .isamplerBuffer },
    .{ .name = "usampler1D", .kind = .usampler1D },
    .{ .name = "usampler2D", .kind = .usampler2D },
    .{ .name = "usampler3D", .kind = .usampler3D },
    .{ .name = "usamplerCube", .kind = .usamplerCube },
    .{ .name = "usampler2DArray", .kind = .usampler2DArray },
    .{ .name = "usamplerBuffer", .kind = .usamplerBuffer },
};

pub fn fromBuiltinName(name: []const u8) ?Type {
    if (std.mem.eql(u8, name, "void")) return .void_;
    if (std.mem.eql(u8, name, "float")) return .{ .scalar = .float };
    if (std.mem.eql(u8, name, "int")) return .{ .scalar = .int };
    if (std.mem.eql(u8, name, "uint")) return .{ .scalar = .uint };
    if (std.mem.eql(u8, name, "bool")) return .{ .scalar = .bool };
    if (std.mem.eql(u8, name, "double")) return .{ .scalar = .double };

    const vector_prefixes = [_]struct { prefix: []const u8, scalar: Scalar }{
        .{ .prefix = "vec", .scalar = .float },
        .{ .prefix = "ivec", .scalar = .int },
        .{ .prefix = "uvec", .scalar = .uint },
        .{ .prefix = "bvec", .scalar = .bool },
        .{ .prefix = "dvec", .scalar = .double },
    };
    for (vector_prefixes) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) {
            const suffix = name[entry.prefix.len..];
            const len = parseSize(suffix) orelse continue;
            if (len < 2) continue;
            return .{ .vector = .{ .scalar = entry.scalar, .len = len } };
        }
    }

    if (std.mem.startsWith(u8, name, "mat")) {
        return parseMatrixName(name[3..]);
    }

    for (sampler_names) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return .{ .sampler = entry.kind };
    }
    return null;
}

fn parseMatrixName(rest: []const u8) ?Type {
    if (rest.len == 0) return null;
    if (std.mem.indexOfScalar(u8, rest, 'x')) |split| {
        if (split == 0 or split + 1 >= rest.len) return null;
        const cols = parseSize(rest[0..split]) orelse return null;
        const rows = parseSize(rest[split + 1 ..]) orelse return null;
        if (cols < 2 or cols > 4 or rows < 2 or rows > 4) return null;
        return .{ .matrix = .{ .cols = cols, .rows = rows } };
    }
    const size = parseSize(rest) orelse return null;
    if (size < 2 or size > 4) return null;
    return .{ .matrix = .{ .cols = size, .rows = size } };
}

fn parseSize(text: []const u8) ?u8 {
    if (text.len != 1) return null;
    const c = text[0];
    if (c < '2' or c > '4') return null;
    return c - '0';
}

pub fn isBuiltinTypeName(name: []const u8) bool {
    if (fromBuiltinName(name) != null) return true;
    if (std.mem.startsWith(u8, name, "image")) return true;
    if (std.mem.startsWith(u8, name, "atomic_")) return true;
    return false;
}

pub fn resolveName(name: []const u8, struct_names: []const []const u8) ?Type {
    if (fromBuiltinName(name)) |typ| return typ;
    for (struct_names) |struct_name| {
        if (std.mem.eql(u8, name, struct_name)) return .{ .named = struct_name };
    }
    return null;
}

pub fn commonScalar(a: Scalar, b: Scalar) Scalar {
    if (a == .double or b == .double) return .double;
    if (a == .float or b == .float) return .float;
    if (a == .uint or b == .uint) return .uint;
    return .int;
}
