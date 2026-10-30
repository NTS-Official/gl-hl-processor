const std = @import("std");

pub const Intrinsic = enum {
    passthrough,
    mix,
    fract,
    inversesqrt,
    ddx,
    ddy,
    atan2,
    matrix_comp_mult,
    fma,
    mod,
    texture,
    texture_lod,
    texture_grad,
    texel_fetch,
    compare,
    logical_not,
    unsupported,
};

pub fn classify(name: []const u8) Intrinsic {
    const direct = [_]struct { name: []const u8, intrinsic: Intrinsic }{
        .{ .name = "mix", .intrinsic = .mix },
        .{ .name = "fract", .intrinsic = .fract },
        .{ .name = "inversesqrt", .intrinsic = .inversesqrt },
        .{ .name = "dFdx", .intrinsic = .ddx },
        .{ .name = "dFdy", .intrinsic = .ddy },
        .{ .name = "matrixCompMult", .intrinsic = .matrix_comp_mult },
        .{ .name = "fma", .intrinsic = .fma },
        .{ .name = "mod", .intrinsic = .mod },
        .{ .name = "texture", .intrinsic = .texture },
        .{ .name = "texture1D", .intrinsic = .texture },
        .{ .name = "texture2D", .intrinsic = .texture },
        .{ .name = "texture3D", .intrinsic = .texture },
        .{ .name = "textureCube", .intrinsic = .texture },
        .{ .name = "textureLod", .intrinsic = .texture_lod },
        .{ .name = "texture1DLod", .intrinsic = .texture_lod },
        .{ .name = "texture2DLod", .intrinsic = .texture_lod },
        .{ .name = "texture3DLod", .intrinsic = .texture_lod },
        .{ .name = "textureCubeLod", .intrinsic = .texture_lod },
        .{ .name = "textureGrad", .intrinsic = .texture_grad },
        .{ .name = "texture1DGrad", .intrinsic = .texture_grad },
        .{ .name = "texture2DGrad", .intrinsic = .texture_grad },
        .{ .name = "texture3DGrad", .intrinsic = .texture_grad },
        .{ .name = "textureCubeGrad", .intrinsic = .texture_grad },
        .{ .name = "texelFetch", .intrinsic = .texel_fetch },
        .{ .name = "lessThan", .intrinsic = .compare },
        .{ .name = "lessThanEqual", .intrinsic = .compare },
        .{ .name = "greaterThan", .intrinsic = .compare },
        .{ .name = "greaterThanEqual", .intrinsic = .compare },
        .{ .name = "equal", .intrinsic = .compare },
        .{ .name = "notEqual", .intrinsic = .compare },
        .{ .name = "not", .intrinsic = .logical_not },
    };
    for (direct) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.intrinsic;
    }
    if (isPassthrough(name)) return .passthrough;
    return .unsupported;
}

pub fn isPassthrough(name: []const u8) bool {
    const names = [_][]const u8{
        "sin",       "cos",         "tan",         "asin",      "acos",
        "atan",      "sinh",        "cosh",        "tanh",      "asinh",
        "acosh",     "atanh",       "pow",         "exp",       "log",
        "exp2",      "log2",        "sqrt",        "abs",       "sign",
        "floor",     "ceil",        "round",       "roundEven", "trunc",
        "radians",   "degrees",     "clamp",       "min",       "max",
        "step",      "smoothstep",  "length",      "distance",  "dot",
        "cross",     "normalize",   "faceforward", "reflect",   "refract",
        "any",       "all",         "isnan",       "isinf",     "fwidth",
        "transpose", "determinant", "log10",
    };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub fn hlslName(intrinsic: Intrinsic) []const u8 {
    return switch (intrinsic) {
        .mix => "lerp",
        .fract => "frac",
        .inversesqrt => "rsqrt",
        .ddx => "ddx",
        .ddy => "ddy",
        .fma => "mad",
        .texture => "Sample",
        .texture_lod => "SampleLevel",
        .texture_grad => "SampleGrad",
        .texel_fetch => "Load",
        else => "",
    };
}

pub fn compareOperator(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "lessThan")) return "<";
    if (std.mem.eql(u8, name, "lessThanEqual")) return "<=";
    if (std.mem.eql(u8, name, "greaterThan")) return ">";
    if (std.mem.eql(u8, name, "greaterThanEqual")) return ">=";
    if (std.mem.eql(u8, name, "equal")) return "==";
    if (std.mem.eql(u8, name, "notEqual")) return "!=";
    return null;
}
