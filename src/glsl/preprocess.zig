const std = @import("std");
const diag = @import("../diag.zig");

pub const Result = struct {
    source: []const u8,
    version: ?[]const u8,
};

pub const Error = error{ InvalidShader, OutOfMemory };

const Macro = struct {
    name: []const u8,
    value: []const u8,
};

const Condition = struct {
    parent_active: bool,
    active: bool,
    taken: bool,
    line: u32,
};

pub fn preprocess(allocator: std.mem.Allocator, input: []const u8, diagnostics: *diag.Diagnostics) Error!Result {
    const stripped = try stripComments(allocator, input, diagnostics);
    var pp = Preprocessor{
        .allocator = allocator,
        .diagnostics = diagnostics,
    };
    try pp.run(stripped);
    return .{
        .source = try pp.output.toOwnedSlice(allocator),
        .version = pp.version,
    };
}

const Preprocessor = struct {
    allocator: std.mem.Allocator,
    diagnostics: *diag.Diagnostics,
    macros: std.ArrayList(Macro) = .empty,
    conditions: std.ArrayList(Condition) = .empty,
    output: std.ArrayList(u8) = .empty,
    version: ?[]const u8 = null,

    fn run(self: *Preprocessor, source: []const u8) Error!void {
        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_number: u32 = 0;
        while (lines.next()) |line| {
            line_number += 1;
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '#') {
                try self.directive(trimmed, line_number);
            } else if (self.active()) {
                try self.expandLine(line);
            }
            try self.output.append(self.allocator, '\n');
        }
        if (self.conditions.items.len > 0) {
            const cond = self.conditions.items[self.conditions.items.len - 1];
            try self.diagnostics.errFmt(cond.line, 1, "unterminated conditional directive", .{});
            return error.InvalidShader;
        }
    }

    fn active(self: *const Preprocessor) bool {
        if (self.conditions.items.len == 0) return true;
        return self.conditions.items[self.conditions.items.len - 1].active;
    }

    fn directive(self: *Preprocessor, line: []const u8, line_number: u32) Error!void {
        const rest = std.mem.trimStart(u8, line[1..], " \t");
        var name_end: usize = 0;
        while (name_end < rest.len and
            (rest[name_end] == '_' or std.ascii.isAlphabetic(rest[name_end]))) : (name_end += 1)
        {}
        const name = rest[0..name_end];
        const arg = std.mem.trim(u8, rest[name_end..], " \t");

        if (name.len == 0) {
            try self.diagnostics.warn(line_number, 1, "empty preprocessor directive");
            return;
        }

        if (std.mem.eql(u8, name, "version")) {
            if (self.version == null) self.version = arg;
            return;
        }
        if (std.mem.eql(u8, name, "extension") or
            std.mem.eql(u8, name, "pragma") or
            std.mem.eql(u8, name, "line"))
        {
            return;
        }
        if (std.mem.eql(u8, name, "define")) {
            if (!self.active()) return;
            try self.define(arg, line_number);
            return;
        }
        if (std.mem.eql(u8, name, "undef")) {
            if (!self.active()) return;
            const macro_name = firstIdentifier(arg);
            if (macro_name.len == 0) {
                try self.diagnostics.err(line_number, 1, "expected a macro name after #undef");
                return;
            }
            self.removeMacro(macro_name);
            return;
        }
        if (std.mem.eql(u8, name, "ifdef") or std.mem.eql(u8, name, "ifndef")) {
            const parent = self.active();
            const macro_name = firstIdentifier(arg);
            const defined = self.findMacro(macro_name) != null;
            const value = if (std.mem.eql(u8, name, "ifdef")) defined else !defined;
            const is_active = parent and value;
            try self.conditions.append(self.allocator, .{
                .parent_active = parent,
                .active = is_active,
                .taken = is_active,
                .line = line_number,
            });
            return;
        }
        if (std.mem.eql(u8, name, "if")) {
            const parent = self.active();
            var value = false;
            if (parent) value = (try self.evaluate(arg, line_number)) != 0;
            const is_active = parent and value;
            try self.conditions.append(self.allocator, .{
                .parent_active = parent,
                .active = is_active,
                .taken = is_active,
                .line = line_number,
            });
            return;
        }
        if (std.mem.eql(u8, name, "elif")) {
            if (self.conditions.items.len == 0) {
                try self.diagnostics.err(line_number, 1, "#elif without #if");
                return;
            }
            const cond = &self.conditions.items[self.conditions.items.len - 1];
            var value = false;
            if (cond.parent_active and !cond.taken) value = (try self.evaluate(arg, line_number)) != 0;
            cond.active = cond.parent_active and !cond.taken and value;
            cond.taken = cond.taken or cond.active;
            return;
        }
        if (std.mem.eql(u8, name, "else")) {
            if (self.conditions.items.len == 0) {
                try self.diagnostics.err(line_number, 1, "#else without #if");
                return;
            }
            const cond = &self.conditions.items[self.conditions.items.len - 1];
            cond.active = cond.parent_active and !cond.taken;
            cond.taken = true;
            return;
        }
        if (std.mem.eql(u8, name, "endif")) {
            if (self.conditions.items.len == 0) {
                try self.diagnostics.err(line_number, 1, "#endif without #if");
                return;
            }
            _ = self.conditions.pop();
            return;
        }
        if (std.mem.eql(u8, name, "error")) {
            if (self.active()) {
                try self.diagnostics.errFmt(line_number, 1, "#error {s}", .{arg});
                return error.InvalidShader;
            }
            return;
        }
        if (std.mem.eql(u8, name, "warning")) {
            if (self.active()) try self.diagnostics.warnFmt(line_number, 1, "#warning {s}", .{arg});
            return;
        }
        if (std.mem.eql(u8, name, "include")) {
            if (self.active()) {
                try self.diagnostics.err(line_number, 1, "#include is not supported; inline the file before conversion");
                return error.InvalidShader;
            }
            return;
        }
        try self.diagnostics.warnFmt(line_number, 1, "unknown preprocessor directive '#{s}'", .{name});
    }

    fn define(self: *Preprocessor, arg: []const u8, line_number: u32) Error!void {
        const name = firstIdentifier(arg);
        if (name.len == 0) {
            try self.diagnostics.err(line_number, 1, "expected a macro name after #define");
            return;
        }
        const after_name = arg[name.len..];
        if (after_name.len > 0 and after_name[0] == '(') {
            try self.diagnostics.errFmt(line_number, 1, "function-like macro '{s}' is not supported", .{name});
            return error.InvalidShader;
        }
        const value = std.mem.trimStart(u8, after_name, " \t");
        for (self.macros.items) |*macro| {
            if (std.mem.eql(u8, macro.name, name)) {
                macro.value = value;
                return;
            }
        }
        try self.macros.append(self.allocator, .{ .name = name, .value = value });
    }

    fn removeMacro(self: *Preprocessor, name: []const u8) void {
        for (self.macros.items, 0..) |macro, i| {
            if (std.mem.eql(u8, macro.name, name)) {
                _ = self.macros.swapRemove(i);
                return;
            }
        }
    }

    fn findMacro(self: *const Preprocessor, name: []const u8) ?*const Macro {
        for (self.macros.items) |*macro| {
            if (std.mem.eql(u8, macro.name, name)) return macro;
        }
        return null;
    }

    fn expandLine(self: *Preprocessor, line: []const u8) Error!void {
        try self.expandInto(line, 0);
    }

    fn expandInto(self: *Preprocessor, text: []const u8, depth: u32) Error!void {
        if (depth > 32) {
            try self.output.appendSlice(self.allocator, text);
            return;
        }
        var i: usize = 0;
        while (i < text.len) {
            if (isIdentStart(text[i])) {
                const start = i;
                i += 1;
                while (i < text.len and isIdentContinue(text[i])) : (i += 1) {}
                const name = text[start..i];
                if (self.findMacro(name)) |macro| {
                    try self.expandInto(macro.value, depth + 1);
                } else {
                    try self.output.appendSlice(self.allocator, name);
                }
            } else {
                try self.output.append(self.allocator, text[i]);
                i += 1;
            }
        }
    }

    fn evaluate(self: *Preprocessor, text: []const u8, line_number: u32) Error!i64 {
        var parser = CondParser{
            .text = text,
            .macros = self.macros.items,
            .diagnostics = self.diagnostics,
            .line = line_number,
        };
        return parser.parse();
    }
};

const CondParser = struct {
    text: []const u8,
    index: usize = 0,
    macros: []const Macro,
    diagnostics: *diag.Diagnostics,
    line: u32,

    fn parse(self: *CondParser) Error!i64 {
        const value = try self.parseOr();
        self.skipSpace();
        if (self.index < self.text.len) {
            try self.diagnostics.errFmt(self.line, 1, "unexpected text in preprocessor expression: '{s}'", .{self.text[self.index..]});
            return error.InvalidShader;
        }
        return value;
    }

    fn parseOr(self: *CondParser) Error!i64 {
        var lhs = try self.parseAnd();
        while (true) {
            self.skipSpace();
            if (self.match("||")) {
                const rhs = try self.parseAnd();
                lhs = @intFromBool(lhs != 0 or rhs != 0);
            } else return lhs;
        }
    }

    fn parseAnd(self: *CondParser) Error!i64 {
        var lhs = try self.parseBitOr();
        while (true) {
            self.skipSpace();
            if (self.match("&&")) {
                const rhs = try self.parseBitOr();
                lhs = @intFromBool(lhs != 0 and rhs != 0);
            } else return lhs;
        }
    }

    fn parseBitOr(self: *CondParser) Error!i64 {
        var lhs = try self.parseBitXor();
        while (true) {
            self.skipSpace();
            if (self.match("|")) {
                const rhs = try self.parseBitXor();
                lhs |= rhs;
            } else return lhs;
        }
    }

    fn parseBitXor(self: *CondParser) Error!i64 {
        var lhs = try self.parseBitAnd();
        while (true) {
            self.skipSpace();
            if (self.match("^")) {
                const rhs = try self.parseBitAnd();
                lhs ^= rhs;
            } else return lhs;
        }
    }

    fn parseBitAnd(self: *CondParser) Error!i64 {
        var lhs = try self.parseEquality();
        while (true) {
            self.skipSpace();
            if (self.match("&")) {
                const rhs = try self.parseEquality();
                lhs &= rhs;
            } else return lhs;
        }
    }

    fn parseEquality(self: *CondParser) Error!i64 {
        var lhs = try self.parseRelational();
        while (true) {
            self.skipSpace();
            if (self.match("==")) {
                const rhs = try self.parseRelational();
                lhs = @intFromBool(lhs == rhs);
            } else if (self.match("!=")) {
                const rhs = try self.parseRelational();
                lhs = @intFromBool(lhs != rhs);
            } else return lhs;
        }
    }

    fn parseRelational(self: *CondParser) Error!i64 {
        var lhs = try self.parseShift();
        while (true) {
            self.skipSpace();
            if (self.match("<=")) {
                const rhs = try self.parseShift();
                lhs = @intFromBool(lhs <= rhs);
            } else if (self.match(">=")) {
                const rhs = try self.parseShift();
                lhs = @intFromBool(lhs >= rhs);
            } else if (self.match("<")) {
                const rhs = try self.parseShift();
                lhs = @intFromBool(lhs < rhs);
            } else if (self.match(">")) {
                const rhs = try self.parseShift();
                lhs = @intFromBool(lhs > rhs);
            } else return lhs;
        }
    }

    fn parseShift(self: *CondParser) Error!i64 {
        var lhs = try self.parseAdd();
        while (true) {
            self.skipSpace();
            if (self.match(">>")) {
                const rhs = try self.parseAdd();
                lhs = shiftRight(lhs, rhs);
            } else if (self.match("<<")) {
                const rhs = try self.parseAdd();
                lhs = shiftLeft(lhs, rhs);
            } else return lhs;
        }
    }

    fn parseAdd(self: *CondParser) Error!i64 {
        var lhs = try self.parseMul();
        while (true) {
            self.skipSpace();
            if (self.match("+")) {
                const rhs = try self.parseMul();
                lhs +%= rhs;
            } else if (self.match("-")) {
                const rhs = try self.parseMul();
                lhs -%= rhs;
            } else return lhs;
        }
    }

    fn parseMul(self: *CondParser) Error!i64 {
        var lhs = try self.parseUnary();
        while (true) {
            self.skipSpace();
            if (self.match("*")) {
                const rhs = try self.parseUnary();
                lhs *%= rhs;
            } else if (self.match("/")) {
                const rhs = try self.parseUnary();
                if (rhs == 0) {
                    try self.diagnostics.err(self.line, 1, "division by zero in preprocessor expression");
                    return error.InvalidShader;
                }
                lhs = @divTrunc(lhs, rhs);
            } else if (self.match("%")) {
                const rhs = try self.parseUnary();
                if (rhs == 0) {
                    try self.diagnostics.err(self.line, 1, "division by zero in preprocessor expression");
                    return error.InvalidShader;
                }
                lhs = @rem(lhs, rhs);
            } else return lhs;
        }
    }

    fn parseUnary(self: *CondParser) Error!i64 {
        self.skipSpace();
        if (self.match("!")) return @intFromBool((try self.parseUnary()) == 0);
        if (self.match("~")) return ~(try self.parseUnary());
        if (self.match("-")) return -(try self.parseUnary());
        if (self.match("+")) return try self.parseUnary();
        return self.parsePrimary();
    }

    fn parsePrimary(self: *CondParser) Error!i64 {
        self.skipSpace();
        if (self.match("(")) {
            const value = try self.parseOr();
            self.skipSpace();
            if (!self.match(")")) {
                try self.diagnostics.err(self.line, 1, "expected ')' in preprocessor expression");
                return error.InvalidShader;
            }
            return value;
        }
        if (self.index < self.text.len and isIdentStart(self.text[self.index])) {
            const start = self.index;
            self.index += 1;
            while (self.index < self.text.len and isIdentContinue(self.text[self.index])) : (self.index += 1) {}
            const name = self.text[start..self.index];
            if (std.mem.eql(u8, name, "defined")) {
                self.skipSpace();
                const paren = self.match("(");
                self.skipSpace();
                const macro_start = self.index;
                while (self.index < self.text.len and isIdentContinue(self.text[self.index])) : (self.index += 1) {}
                const macro_name = self.text[macro_start..self.index];
                if (macro_name.len == 0) {
                    try self.diagnostics.err(self.line, 1, "expected a macro name after defined");
                    return error.InvalidShader;
                }
                if (paren) {
                    self.skipSpace();
                    if (!self.match(")")) {
                        try self.diagnostics.err(self.line, 1, "expected ')' after defined");
                        return error.InvalidShader;
                    }
                }
                return @intFromBool(self.findMacro(macro_name) != null);
            }
            return self.macroValue(name, 0);
        }
        if (self.index < self.text.len and std.ascii.isDigit(self.text[self.index])) {
            const start = self.index;
            while (self.index < self.text.len and
                (std.ascii.isAlphanumeric(self.text[self.index]) or self.text[self.index] == 'x' or
                    self.text[self.index] == 'X')) : (self.index += 1)
            {}
            return self.parseInteger(self.text[start..self.index]);
        }
        try self.diagnostics.err(self.line, 1, "expected an integer in preprocessor expression");
        return error.InvalidShader;
    }

    fn macroValue(self: *CondParser, name: []const u8, depth: u32) Error!i64 {
        if (depth > 16) return 0;
        for (self.macros) |macro| {
            if (std.mem.eql(u8, macro.name, name)) {
                const value = std.mem.trim(u8, macro.value, " \t");
                if (value.len == 0) return 0;
                if (isIdentifier(value)) return self.macroValue(value, depth + 1);
                if (std.ascii.isDigit(value[0])) return self.parseInteger(value);
                return 0;
            }
        }
        return 0;
    }

    fn parseInteger(self: *CondParser, text: []const u8) Error!i64 {
        var cleaned = std.mem.trim(u8, text, " \t");
        if (cleaned.len > 0 and (cleaned[cleaned.len - 1] == 'u' or cleaned[cleaned.len - 1] == 'U')) {
            cleaned = cleaned[0 .. cleaned.len - 1];
        }
        if (cleaned.len == 0) return 0;
        if (cleaned.len > 2 and cleaned[0] == '0' and (cleaned[1] == 'x' or cleaned[1] == 'X')) {
            return std.fmt.parseInt(i64, cleaned[2..], 16) catch {
                try self.diagnostics.errFmt(self.line, 1, "invalid integer literal '{s}'", .{text});
                return error.InvalidShader;
            };
        }
        return std.fmt.parseInt(i64, cleaned, 10) catch {
            try self.diagnostics.errFmt(self.line, 1, "invalid integer literal '{s}'", .{text});
            return error.InvalidShader;
        };
    }

    fn findMacro(self: *CondParser, name: []const u8) ?Macro {
        for (self.macros) |macro| {
            if (std.mem.eql(u8, macro.name, name)) return macro;
        }
        return null;
    }

    fn skipSpace(self: *CondParser) void {
        while (self.index < self.text.len and
            (self.text[self.index] == ' ' or self.text[self.index] == '\t' or self.text[self.index] == '\r')) : (self.index += 1)
        {}
    }

    fn match(self: *CondParser, text: []const u8) bool {
        if (self.index + text.len > self.text.len) return false;
        if (!std.mem.eql(u8, self.text[self.index .. self.index + text.len], text)) return false;
        self.index += text.len;
        return true;
    }
};

fn shiftLeft(value: i64, amount: i64) i64 {
    if (amount < 0 or amount >= 64) return 0;
    const bits: u64 = @bitCast(value);
    return @bitCast(bits << @intCast(amount));
}

fn shiftRight(value: i64, amount: i64) i64 {
    if (amount < 0 or amount >= 64) return if (value < 0) -1 else 0;
    return value >> @intCast(amount);
}

fn stripComments(allocator: std.mem.Allocator, input: []const u8, diagnostics: *diag.Diagnostics) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var line: u32 = 1;
    var column: u32 = 1;

    while (i < input.len) {
        const c = input[i];
        if (c == '/' and i + 1 < input.len and input[i + 1] == '/') {
            while (i < input.len and input[i] != '\n') : (i += 1) {
                try output.append(allocator, ' ');
                column += 1;
            }
            continue;
        }
        if (c == '/' and i + 1 < input.len and input[i + 1] == '*') {
            const start_line = line;
            const start_column = column;
            i += 2;
            column += 2;
            var closed = false;
            while (i < input.len) {
                if (i + 1 < input.len and input[i] == '*' and input[i + 1] == '/') {
                    i += 2;
                    column += 2;
                    closed = true;
                    break;
                }
                const cc = input[i];
                if (cc == '\n') {
                    try output.append(allocator, '\n');
                    line += 1;
                    column = 1;
                } else if (cc == '\r') {
                    if (i + 1 < input.len and input[i + 1] == '\n') i += 1;
                    try output.append(allocator, '\n');
                    line += 1;
                    column = 1;
                } else {
                    try output.append(allocator, ' ');
                    column += 1;
                }
                i += 1;
            }
            if (!closed) {
                try diagnostics.errFmt(start_line, start_column, "unterminated block comment", .{});
                return error.InvalidShader;
            }
            continue;
        }
        if (c == '\r') {
            if (i + 1 < input.len and input[i + 1] == '\n') i += 1;
            try output.append(allocator, '\n');
            line += 1;
            column = 1;
            i += 1;
            continue;
        }
        try output.append(allocator, c);
        if (c == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
        i += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn firstIdentifier(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < text.len and isIdentContinue(text[i])) : (i += 1) {}
    return text[start..i];
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or !isIdentStart(text[0])) return false;
    for (text[1..]) |c| {
        if (!isIdentContinue(c)) return false;
    }
    return true;
}

fn isIdentStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}

fn isIdentContinue(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

test "preprocess version and object macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const result = try preprocess(allocator,
        \\#version 330 core
        \\#define SCALE 2.0
        \\void main() { float x = SCALE; }
    , &diagnostics);
    try std.testing.expectEqualStrings("330 core", result.version.?);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "float x = 2.0;") != null);
}

test "preprocess conditionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const result = try preprocess(allocator,
        \\#define USE_A 1
        \\#if USE_A
        \\float a;
        \\#else
        \\float b;
        \\#endif
        \\#ifndef USE_A
        \\float c;
        \\#endif
    , &diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "float a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "float b;") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "float c;") == null);
}

test "preprocess strips comments but keeps line count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const result = try preprocess(allocator,
        \\// one
        \\float a; /* two
        \\three */
        \\float b;
    , &diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "float a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "float b;") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, result.source, "\n"));
}

test "preprocess reports unsupported function macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    try std.testing.expectError(error.InvalidShader, preprocess(arena.allocator(),
        \\#define FOO(x) (x)
        \\float a;
    , &diagnostics));
    try std.testing.expect(diagnostics.hasErrors());
}
