const std = @import("std");
const processor = @import("processor");

const usage =
    \\usage: glsl2hlsl [options] <input.glsl>
    \\
    \\options:
    \\  -o <path>              write HLSL to <path> instead of stdout
    \\  -s, --stage <stage>    vertex or fragment (inferred when omitted)
    \\  -h, --help             show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var stage: ?processor.options.Stage = null;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "-o")) {
            index += 1;
            if (index >= args.len) return fatal(io, "missing path after -o", .{});
            output_path = args[index];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--stage")) {
            index += 1;
            if (index >= args.len) return fatal(io, "missing stage after --stage", .{});
            stage = processor.options.Stage.parse(args[index]) orelse
                return fatal(io, "unknown stage '{s}'; expected vertex or fragment", .{args[index]});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return fatal(io, "unknown option '{s}'", .{arg});
        } else if (input_path == null) {
            input_path = arg;
        } else {
            return fatal(io, "unexpected argument '{s}'", .{arg});
        }
    }

    const path = input_path orelse return fatal(io, "no input file", .{});
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        return fatal(io, "cannot read '{s}': {s}", .{ path, @errorName(err) });
    };

    var diagnostics = processor.diag.Diagnostics.init(allocator);
    const output = processor.convert(allocator, source, .{ .stage = stage }, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidShader => {
            try printDiagnostics(io, path, diagnostics.items.items);
            std.process.exit(1);
        },
    };
    try printDiagnostics(io, path, diagnostics.items.items);

    if (output_path) |destination| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = output, .flags = .{} }) catch |err| {
            return fatal(io, "cannot write '{s}': {s}", .{ destination, @errorName(err) });
        };
    } else {
        try std.Io.File.stdout().writeStreamingAll(io, output);
    }
}

fn printDiagnostics(io: std.Io, path: []const u8, diagnostics: []const processor.diag.Diagnostic) !void {
    for (diagnostics) |diagnostic| {
        const label = switch (diagnostic.kind) {
            .err => "error",
            .warning => "warning",
        };
        var buffer: [2048]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{s}:{d}:{d}: {s}: {s}\n", .{
            path,
            diagnostic.line,
            diagnostic.column,
            label,
            diagnostic.message,
        }) catch continue;
        try std.Io.File.stderr().writeStreamingAll(io, text);
    }
}

fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buffer: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "glsl2hlsl: " ++ fmt ++ "\n", args) catch "glsl2hlsl: error\n";
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
    std.process.exit(2);
}
