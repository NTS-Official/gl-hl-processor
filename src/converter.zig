const std = @import("std");
const diag = @import("diag.zig");
const options = @import("options.zig");
const preprocess = @import("glsl/preprocess.zig");
const token = @import("glsl/token.zig");
const parser = @import("glsl/parser.zig");
const ast = @import("glsl/ast.zig");
const emitter = @import("hlsl/emitter.zig");

pub const Error = error{ InvalidShader, OutOfMemory };

pub fn convert(
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: options.Options,
    diagnostics: *diag.Diagnostics,
) Error![]const u8 {
    const preprocessed = try preprocess.preprocess(allocator, source, diagnostics);
    const tokens = try token.tokenize(allocator, preprocessed.source, diagnostics);
    var shader_parser = parser.Parser.init(allocator, tokens, diagnostics);
    const unit = try shader_parser.parse();
    const stage: ast.Stage = if (opts.stage) |requested| switch (requested) {
        .vertex => .vertex,
        .fragment => .fragment,
    } else try emitter.inferStage(unit, diagnostics);
    return emitter.emit(allocator, unit, stage, diagnostics);
}
