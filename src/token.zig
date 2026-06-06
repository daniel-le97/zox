const std = @import("std");
const value = @import("value.zig");

pub const LiteralValue = value.Value;

pub const TokenType = enum {
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    comma,
    dot,
    minus,
    plus,
    semicolon,
    slash,
    star,

    bang,
    bang_equal,
    equal,
    equal_equal,
    greater,
    greater_equal,
    less,
    less_equal,

    identifier,
    string,
    number,

    and_kw,
    class_kw,
    else_kw,
    false_kw,
    import_kw,
    fun_kw,
    for_kw,
    if_kw,
    module_kw,
    nil_kw,
    as_kw,
    or_kw,
    print_kw,
    return_kw,
    super_kw,
    this_kw,
    true_kw,
    var_kw,
    while_kw,

    eof,
};

pub const Token = struct {
    typ: TokenType,
    lexeme: []const u8,
    literal: ?LiteralValue = null,
    line: usize,

    pub fn is(self: Token, typ: TokenType) bool {
        return self.typ == typ;
    }
};
