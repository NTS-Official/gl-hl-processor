const std = @import("std");

pub const Stage = enum {
    vertex,
    fragment,

    pub fn parse(text: []const u8) ?Stage {
        if (std.mem.eql(u8, text, "vertex") or std.mem.eql(u8, text, "vert")) return .vertex;
        if (std.mem.eql(u8, text, "fragment") or std.mem.eql(u8, text, "frag")) return .fragment;
        return null;
    }
};

pub const Options = struct {
    stage: ?Stage = null,
};
