const std = @import("std");
const diag = @import("../diag.zig");

pub const Kind = enum {
    eof,
    identifier,
    int_literal,
    uint_literal,
    float_literal,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    dot,
    comma,
    semicolon,
    colon,
    question,
    plus,
    minus,
    star,
    slash,
    percent,
    plus_plus,
    minus_minus,
    equal,
    equal_equal,
    bang,
    bang_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    amp,
    amp_amp,
    pipe,
    pipe_pipe,
    caret,
    tilde,
    less_less,
    greater_greater,
    plus_equal,
    minus_equal,
    star_equal,
    slash_equal,
    percent_equal,
    amp_equal,
    pipe_equal,
    caret_equal,
    less_less_equal,
    greater_greater_equal,
};

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    line: u32,
    column: u32,
};

pub const LexError = error{ InvalidShader, OutOfMemory };

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8, diagnostics: *diag.Diagnostics) LexError![]Token {
    var lexer = Lexer{
        .source = source,
        .diagnostics = diagnostics,
    };
    var list: std.ArrayList(Token) = .empty;
    while (true) {
        const tok = try lexer.next();
        try list.append(allocator, tok);
        if (tok.kind == .eof) break;
    }
    return list.toOwnedSlice(allocator);
}

const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    diagnostics: *diag.Diagnostics,

    fn next(self: *Lexer) LexError!Token {
        try self.skipTrivia();
        const start = self.index;
        const line = self.line;
        const column = self.column;
        if (self.index >= self.source.len) {
            return .{ .kind = .eof, .text = "", .line = line, .column = column };
        }

        const c = self.source[self.index];
        if (isIdentStart(c)) return self.lexIdentifier(start, line, column);
        if (std.ascii.isDigit(c) or
            (c == '.' and self.index + 1 < self.source.len and std.ascii.isDigit(self.source[self.index + 1])))
        {
            return self.lexNumber(start, line, column);
        }

        self.bump();
        const kind: Kind = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            '.' => .dot,
            ',' => .comma,
            ';' => .semicolon,
            ':' => .colon,
            '?' => .question,
            '+' => blk: {
                if (self.match('+')) break :blk .plus_plus;
                if (self.match('=')) break :blk .plus_equal;
                break :blk .plus;
            },
            '-' => blk: {
                if (self.match('-')) break :blk .minus_minus;
                if (self.match('=')) break :blk .minus_equal;
                break :blk .minus;
            },
            '*' => if (self.match('=')) .star_equal else .star,
            '/' => if (self.match('=')) .slash_equal else .slash,
            '%' => if (self.match('=')) .percent_equal else .percent,
            '=' => if (self.match('=')) .equal_equal else .equal,
            '!' => if (self.match('=')) .bang_equal else .bang,
            '<' => blk: {
                if (self.match('<')) {
                    if (self.match('=')) break :blk .less_less_equal;
                    break :blk .less_less;
                }
                if (self.match('=')) break :blk .less_equal;
                break :blk .less;
            },
            '>' => blk: {
                if (self.match('>')) {
                    if (self.match('=')) break :blk .greater_greater_equal;
                    break :blk .greater_greater;
                }
                if (self.match('=')) break :blk .greater_equal;
                break :blk .greater;
            },
            '&' => blk: {
                if (self.match('&')) break :blk .amp_amp;
                if (self.match('=')) break :blk .amp_equal;
                break :blk .amp;
            },
            '|' => blk: {
                if (self.match('|')) break :blk .pipe_pipe;
                if (self.match('=')) break :blk .pipe_equal;
                break :blk .pipe;
            },
            '^' => if (self.match('=')) .caret_equal else .caret,
            '~' => .tilde,
            else => {
                try self.diagnostics.errFmt(line, column, "unexpected character '{c}'", .{c});
                return error.InvalidShader;
            },
        };
        return .{ .kind = kind, .text = self.source[start..self.index], .line = line, .column = column };
    }

    fn lexIdentifier(self: *Lexer, start: usize, line: u32, column: u32) Token {
        self.bump();
        while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.bump();
        }
        return .{ .kind = .identifier, .text = self.source[start..self.index], .line = line, .column = column };
    }

    fn lexNumber(self: *Lexer, start: usize, line: u32, column: u32) LexError!Token {
        var kind: Kind = .int_literal;
        const first = self.source[self.index];

        if (first == '.') {
            kind = .float_literal;
            self.bump();
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.bump();
        } else if (first == '0' and self.index + 1 < self.source.len and
            (self.source[self.index + 1] == 'x' or self.source[self.index + 1] == 'X'))
        {
            self.bump();
            self.bump();
            const digits_start = self.index;
            while (self.index < self.source.len and std.ascii.isHex(self.source[self.index])) self.bump();
            if (self.index == digits_start) {
                try self.diagnostics.errFmt(line, column, "hexadecimal literal has no digits", .{});
                return error.InvalidShader;
            }
            if (self.match('u') or self.match('U')) kind = .uint_literal;
            return .{ .kind = kind, .text = self.source[start..self.index], .line = line, .column = column };
        } else {
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.bump();
            if (self.index < self.source.len and self.source[self.index] == '.' and
                !(self.index + 1 < self.source.len and self.source[self.index + 1] == '.'))
            {
                kind = .float_literal;
                self.bump();
                while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.bump();
            }
            if (self.index < self.source.len and
                (self.source[self.index] == 'e' or self.source[self.index] == 'E'))
            {
                kind = .float_literal;
                self.bump();
                if (self.index < self.source.len and
                    (self.source[self.index] == '+' or self.source[self.index] == '-')) self.bump();
                const digits_start = self.index;
                while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.bump();
                if (self.index == digits_start) {
                    try self.diagnostics.errFmt(line, column, "exponent has no digits", .{});
                    return error.InvalidShader;
                }
            }
        }

        if (self.index < self.source.len) {
            const suffix = self.source[self.index];
            if (suffix == 'f' or suffix == 'F') {
                if (kind != .float_literal) {
                    try self.diagnostics.errFmt(line, column, "invalid suffix on integer literal", .{});
                    return error.InvalidShader;
                }
                self.bump();
            } else if (suffix == 'u' or suffix == 'U') {
                if (kind != .int_literal) {
                    try self.diagnostics.errFmt(line, column, "invalid suffix on floating literal", .{});
                    return error.InvalidShader;
                }
                kind = .uint_literal;
                self.bump();
            } else if ((suffix == 'l' or suffix == 'L') and kind == .float_literal and
                self.index + 1 < self.source.len and
                (self.source[self.index + 1] == 'f' or self.source[self.index + 1] == 'F'))
            {
                self.bump();
                self.bump();
            }
        }
        return .{ .kind = kind, .text = self.source[start..self.index], .line = line, .column = column };
    }

    fn skipTrivia(self: *Lexer) LexError!void {
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                ' ', '\t', '\r', '\n' => self.bump(),
                '/' => {
                    if (self.index + 1 >= self.source.len) return;
                    const next_c = self.source[self.index + 1];
                    if (next_c == '/') {
                        while (self.index < self.source.len and self.source[self.index] != '\n') self.bump();
                    } else if (next_c == '*') {
                        const line = self.line;
                        const column = self.column;
                        self.bump();
                        self.bump();
                        while (true) {
                            if (self.index + 1 >= self.source.len) {
                                try self.diagnostics.errFmt(line, column, "unterminated block comment", .{});
                                return error.InvalidShader;
                            }
                            if (self.source[self.index] == '*' and self.source[self.index + 1] == '/') {
                                self.bump();
                                self.bump();
                                break;
                            }
                            self.bump();
                        }
                    } else return;
                },
                else => return,
            }
        }
    }

    fn bump(self: *Lexer) void {
        const c = self.source[self.index];
        self.index += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.index >= self.source.len) return false;
        if (self.source[self.index] != expected) return false;
        self.bump();
        return true;
    }
};

fn isIdentStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}

fn isIdentContinue(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

test "tokenize punctuation with maximal munch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const tokens = try tokenize(allocator, "a <<= b >>= c && d || e == f != g <= h >= i ++ -- += -= *= /= %= &= |= ^=", &diagnostics);
    const expected = [_]Kind{
        .identifier,    .less_less_equal, .identifier,  .greater_greater_equal, .identifier,
        .amp_amp,       .identifier,      .pipe_pipe,   .identifier,            .equal_equal,
        .identifier,    .bang_equal,      .identifier,  .less_equal,            .identifier,
        .greater_equal, .identifier,      .plus_plus,   .minus_minus,           .plus_equal,
        .minus_equal,   .star_equal,      .slash_equal, .percent_equal,         .amp_equal,
        .pipe_equal,    .caret_equal,     .eof,
    };
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |kind, i| try std.testing.expectEqual(kind, tokens[i].kind);
}

test "tokenize numeric literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const tokens = try tokenize(allocator, "1 2u 0x1F 1.0 0.5 .25 1e-3 1.5f 2.0lf", &diagnostics);
    const expected = [_]Kind{
        .int_literal,   .uint_literal,  .int_literal,   .float_literal, .float_literal,
        .float_literal, .float_literal, .float_literal, .float_literal, .eof,
    };
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |kind, i| try std.testing.expectEqual(kind, tokens[i].kind);
}

test "tokenize reports unterminated block comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    try std.testing.expectError(error.InvalidShader, tokenize(arena.allocator(), "/* nope", &diagnostics));
    try std.testing.expect(diagnostics.hasErrors());
}

test "token positions are one based" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const tokens = try tokenize(allocator, "void\n  main", &diagnostics);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].line);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].column);
    try std.testing.expectEqual(@as(u32, 2), tokens[1].line);
    try std.testing.expectEqual(@as(u32, 3), tokens[1].column);
}
