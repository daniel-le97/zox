const std = @import("std");
const token = @import("token.zig");

const Scanner = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize = 0,
    current: usize = 0,
    line: usize = 1,
    tokens: std.ArrayListUnmanaged(token.Token) = .{
        .items = &[_]token.Token{},
        .capacity = 0,
    },

    fn init(allocator: std.mem.Allocator, source: []const u8) Scanner {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    fn scanTokens(self: *Scanner) !void {
        while (!self.isAtEnd()) {
            self.start = self.current;
            try self.scanToken();
        }

        try self.addToken(.eof, null);
    }

    fn scanToken(self: *Scanner) !void {
        const c = self.advance();

        switch (c) {
            '(' => try self.addToken(.left_paren, null),
            ')' => try self.addToken(.right_paren, null),
            '{' => try self.addToken(.left_brace, null),
            '}' => try self.addToken(.right_brace, null),
            ',' => try self.addToken(.comma, null),
            '.' => try self.addToken(.dot, null),
            '-' => try self.addToken(.minus, null),
            '+' => try self.addToken(.plus, null),
            ';' => try self.addToken(.semicolon, null),
            '*' => try self.addToken(.star, null),
            '!' => try self.addToken(if (self.match('=')) .bang_equal else .bang, null),
            '=' => try self.addToken(if (self.match('=')) .equal_equal else .equal, null),
            '<' => try self.addToken(if (self.match('=')) .less_equal else .less, null),
            '>' => try self.addToken(if (self.match('=')) .greater_equal else .greater, null),
            '/' => {
                if (self.match('/')) {
                    while (self.peek() != '\n' and !self.isAtEnd()) {
                        _ = self.advance();
                    }
                } else {
                    try self.addToken(.slash, null);
                }
            },
            ' ', '\r', '\t' => {},
            '\n' => self.line += 1,
            '"' => try self.string(),
            else => {
                if (std.ascii.isDigit(c)) {
                    try self.number();
                } else if (isAlpha(c)) {
                    try self.identifier();
                } else {
                    std.debug.print("[line {d}] Unexpected character '{c}'\n", .{ self.line, c });
                    return error.UnexpectedCharacter;
                }
            },
        }
    }

    fn identifier(self: *Scanner) !void {
        while (isAlphaNumeric(self.peek())) {
            _ = self.advance();
        }

        const text = self.source[self.start..self.current];
        const typ = keywordType(text) orelse .identifier;
        try self.addToken(typ, null);
    }

    fn number(self: *Scanner) !void {
        while (std.ascii.isDigit(self.peek())) {
            _ = self.advance();
        }

        if (self.peek() == '.' and std.ascii.isDigit(self.peekNext())) {
            _ = self.advance();
            while (std.ascii.isDigit(self.peek())) {
                _ = self.advance();
            }
        }

        const text = self.source[self.start..self.current];
        const value = try std.fmt.parseFloat(f64, text);
        try self.addToken(.number, .{ .number = value });
    }

    fn string(self: *Scanner) !void {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') {
                self.line += 1;
            }
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            std.debug.print("[line {d}] Unterminated string\n", .{self.line});
            return error.UnterminatedString;
        }

        _ = self.advance();
        const value = self.source[self.start + 1 .. self.current - 1];
        try self.addToken(.string, .{ .string = value });
    }

    fn addToken(self: *Scanner, typ: token.TokenType, literal: ?token.LiteralValue) !void {
        try self.tokens.append(self.allocator, .{
            .typ = typ,
            .lexeme = self.source[self.start..self.current],
            .literal = literal,
            .line = self.line,
        });
    }

    fn advance(self: *Scanner) u8 {
        const c = self.source[self.current];
        self.current += 1;
        return c;
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        return true;
    }

    fn peek(self: *Scanner) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *Scanner) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn isAtEnd(self: *Scanner) bool {
        return self.current >= self.source.len;
    }
};

pub fn scanTokens(allocator: std.mem.Allocator, source: []const u8) !std.ArrayListUnmanaged(token.Token) {
    var scanner = Scanner.init(allocator, source);
    try scanner.scanTokens();
    return scanner.tokens;
}

fn isAlpha(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isAlphaNumeric(c: u8) bool {
    return isAlpha(c) or std.ascii.isDigit(c);
}

fn keywordType(text: []const u8) ?token.TokenType {
    if (std.mem.eql(u8, text, "and")) return .and_kw;
    if (std.mem.eql(u8, text, "class")) return .class_kw;
    if (std.mem.eql(u8, text, "else")) return .else_kw;
    if (std.mem.eql(u8, text, "false")) return .false_kw;
    if (std.mem.eql(u8, text, "import")) return .import_kw;
    if (std.mem.eql(u8, text, "for")) return .for_kw;
    if (std.mem.eql(u8, text, "fun")) return .fun_kw;
    if (std.mem.eql(u8, text, "if")) return .if_kw;
    if (std.mem.eql(u8, text, "module")) return .module_kw;
    if (std.mem.eql(u8, text, "nil")) return .nil_kw;
    if (std.mem.eql(u8, text, "as")) return .as_kw;
    if (std.mem.eql(u8, text, "or")) return .or_kw;
    if (std.mem.eql(u8, text, "print")) return .print_kw;
    if (std.mem.eql(u8, text, "return")) return .return_kw;
    if (std.mem.eql(u8, text, "super")) return .super_kw;
    if (std.mem.eql(u8, text, "this")) return .this_kw;
    if (std.mem.eql(u8, text, "true")) return .true_kw;
    if (std.mem.eql(u8, text, "var")) return .var_kw;
    if (std.mem.eql(u8, text, "while")) return .while_kw;
    return null;
}

test "scanner tokenizes arithmetic" {
    const input = "print 1 + 2;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try scanTokens(arena.allocator(), input);

    try std.testing.expectEqual(@as(usize, 6), tokens.items.len);
    try std.testing.expectEqual(token.TokenType.print_kw, tokens.items[0].typ);
    try std.testing.expectEqual(token.TokenType.number, tokens.items[1].typ);
    try std.testing.expectEqual(token.TokenType.plus, tokens.items[2].typ);
}
