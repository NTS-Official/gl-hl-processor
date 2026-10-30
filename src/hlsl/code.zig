const std = @import("std");

pub const Code = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    indent_level: u32 = 0,
    line_start: bool = true,

    pub fn init(allocator: std.mem.Allocator) Code {
        return .{ .allocator = allocator };
    }

    pub fn write(self: *Code, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.line_start) {
            var i: u32 = 0;
            while (i < self.indent_level * 4) : (i += 1) {
                try self.buf.append(self.allocator, ' ');
            }
            self.line_start = false;
        }
        try self.buf.appendSlice(self.allocator, text);
        if (text[text.len - 1] == '\n') self.line_start = true;
    }

    pub fn print(self: *Code, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch {
            const fallback = try std.fmt.allocPrint(self.allocator, fmt, args);
            try self.write(fallback);
            return;
        };
        try self.write(text);
    }

    pub fn line(self: *Code, text: []const u8) !void {
        try self.write(text);
        try self.buf.append(self.allocator, '\n');
        self.line_start = true;
    }

    pub fn printLine(self: *Code, comptime fmt: []const u8, args: anytype) !void {
        try self.print(fmt, args);
        try self.buf.append(self.allocator, '\n');
        self.line_start = true;
    }

    pub fn blank(self: *Code) !void {
        try self.buf.append(self.allocator, '\n');
        self.line_start = true;
    }

    pub fn push(self: *Code) void {
        self.indent_level += 1;
    }

    pub fn pop(self: *Code) void {
        if (self.indent_level > 0) self.indent_level -= 1;
    }
};
