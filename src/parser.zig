const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

pub const ParseError = error{ UnexpectedToken, ExpectedExpression, ExpectedSemicolon, OutOfMemory };

pub const Parser = struct {
    tokens: []const token.Token,
    current: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, tokens: []const token.Token) Parser {
        return .{ .tokens = tokens, .allocator = allocator };
    }

    pub fn parse(self: *Parser) !std.ArrayListUnmanaged(*ast.Stmt) {
        var statements: std.ArrayListUnmanaged(*ast.Stmt) = .{
            .items = &[_]*ast.Stmt{},
            .capacity = 0,
        };

        while (!self.isAtEnd()) {
            try statements.append(self.allocator, try self.statement());
        }

        return statements;
    }

    fn statement(self: *Parser) ParseError!*ast.Stmt {
        if (self.match(.class_kw)) {
            return self.classDeclaration();
        }

        if (self.match(.module_kw)) {
            return self.moduleDeclaration();
        }

        if (self.match(.import_kw)) {
            return self.importStatement();
        }

        if (self.match(.var_kw)) {
            return self.varDeclaration();
        }

        if (self.match(.fun_kw)) {
            return self.functionDeclaration();
        }

        if (self.match(.for_kw)) {
            return self.forStatement();
        }

        if (self.match(.if_kw)) {
            return self.ifStatement();
        }

        if (self.match(.while_kw)) {
            return self.whileStatement();
        }

        if (self.match(.return_kw)) {
            return self.returnStatement();
        }

        if (self.match(.left_brace)) {
            return self.blockStatement();
        }

        if (self.match(.print_kw)) {
            const value = try self.expression();
            _ = try self.consume(.semicolon, "Expect ';' after value.");
            return try self.makeStmt(.{ .print = value });
        }

        const value = try self.expression();
        _ = try self.consume(.semicolon, "Expect ';' after expression.");
        return try self.makeStmt(.{ .expression = value });
    }

    fn expression(self: *Parser) ParseError!*ast.Expr {
        return self.assignment();
    }

    fn assignment(self: *Parser) ParseError!*ast.Expr {
        const expr = try self.logicalOr();

        if (self.match(.equal)) {
            const equals = self.previous();
            const value = try self.assignment();

            switch (expr.*) {
                .variable => |name| return self.makeExpr(.{ .assign = .{ .name = name, .value = value } }),
                .get => |get_expr| return self.makeExpr(.{ .set = .{ .object = get_expr.object, .name = get_expr.name, .value = value } }),
                else => {
                    self.errorAtToken(equals, "Invalid assignment target.");
                    return error.ExpectedExpression;
                },
            }
        }

        return expr;
    }

    fn logicalOr(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.logicalAnd();

        while (self.match(.or_kw)) {
            const operator = self.previous().typ;
            const right = try self.logicalAnd();
            expr = try self.makeExpr(.{ .logical = .{ .left = expr, .operator = operator, .right = right } });
        }

        return expr;
    }

    fn logicalAnd(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.equality();

        while (self.match(.and_kw)) {
            const operator = self.previous().typ;
            const right = try self.equality();
            expr = try self.makeExpr(.{ .logical = .{ .left = expr, .operator = operator, .right = right } });
        }

        return expr;
    }

    fn equality(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.comparison();

        while (self.match(.bang_equal) or self.match(.equal_equal)) {
            const operator = self.previous().typ;
            const right = try self.comparison();
            expr = try self.makeExpr(.{ .binary = .{ .left = expr, .operator = operator, .right = right } });
        }

        return expr;
    }

    fn comparison(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.term();

        while (self.match(.greater) or self.match(.greater_equal) or self.match(.less) or self.match(.less_equal)) {
            const operator = self.previous().typ;
            const right = try self.term();
            expr = try self.makeExpr(.{ .binary = .{ .left = expr, .operator = operator, .right = right } });
        }

        return expr;
    }

    fn term(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.factor();

        while (self.match(.minus) or self.match(.plus)) {
            const operator = self.previous().typ;
            const right = try self.factor();
            expr = try self.makeExpr(.{ .binary = .{ .left = expr, .operator = operator, .right = right } });
        }

        return expr;
    }

    fn factor(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.unary();

        while (self.match(.slash) or self.match(.star)) {
            const operator = self.previous().typ;
            const right = try self.unary();
            expr = try self.makeExpr(.{ .binary = .{ .left = expr, .operator = operator, .right = right } });
        }

        return expr;
    }

    fn unary(self: *Parser) ParseError!*ast.Expr {
        if (self.match(.bang) or self.match(.minus)) {
            const operator = self.previous().typ;
            const right = try self.unary();
            return self.makeExpr(.{ .unary = .{ .operator = operator, .right = right } });
        }

        return self.call();
    }

    fn call(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.primary();

        while (true) {
            if (self.match(.left_paren)) {
                expr = try self.finishCall(expr);
            } else if (self.match(.dot)) {
                const name = try self.consume(.identifier, "Expect property name after '.'.");
                expr = try self.makeExpr(.{ .get = .{ .object = expr, .name = name.lexeme } });
            } else {
                break;
            }
        }

        return expr;
    }

    fn finishCall(self: *Parser, callee: *ast.Expr) ParseError!*ast.Expr {
        var arguments: std.ArrayListUnmanaged(*ast.Expr) = .{
            .items = &[_]*ast.Expr{},
            .capacity = 0,
        };

        if (!self.check(.right_paren)) {
            while (true) {
                try arguments.append(self.allocator, try self.expression());
                if (!self.match(.comma)) break;
            }
        }

        const paren = try self.consume(.right_paren, "Expect ')' after arguments.");
        return try self.makeExpr(.{ .call = .{ .callee = callee, .paren = paren, .arguments = arguments.items } });
    }

    fn primary(self: *Parser) ParseError!*ast.Expr {
        if (self.match(.false_kw)) return self.makeExpr(.{ .literal = .{ .bool = false } });
        if (self.match(.true_kw)) return self.makeExpr(.{ .literal = .{ .bool = true } });
        if (self.match(.nil_kw)) return self.makeExpr(.{ .literal = .nil });
        if (self.match(.this_kw)) return self.makeExpr(.{ .variable = "this" });

        if (self.match(.super_kw)) {
            const keyword = self.previous();
            _ = try self.consume(.dot, "Expect '.' after 'super'.");
            const method = try self.consume(.identifier, "Expect superclass method name.");
            return self.makeExpr(.{ .super_expr = .{ .keyword = keyword, .method = method.lexeme } });
        }

        if (self.match(.number) or self.match(.string)) {
            const lit = self.previous().literal orelse return error.ExpectedExpression;
            return self.makeExpr(.{ .literal = lit });
        }

        if (self.match(.identifier)) {
            return self.makeExpr(.{ .variable = self.previous().lexeme });
        }

        if (self.match(.left_paren)) {
            const expr = try self.expression();
            _ = try self.consume(.right_paren, "Expect ')' after expression.");
            return self.makeExpr(.{ .grouping = expr });
        }

        self.errorAtCurrent("Expect expression.");
        return error.ExpectedExpression;
    }

    fn consume(self: *Parser, typ: token.TokenType, message: []const u8) ParseError!token.Token {
        if (self.check(typ)) return self.advance();
        self.errorAtCurrent(message);
        return error.UnexpectedToken;
    }

    fn functionDeclaration(self: *Parser) ParseError!*ast.Stmt {
        const name = try self.consume(.identifier, "Expect function name.");
        _ = try self.consume(.left_paren, "Expect '(' after function name.");

        var params: std.ArrayListUnmanaged([]const u8) = .{
            .items = &[_][]const u8{},
            .capacity = 0,
        };
        if (!self.check(.right_paren)) {
            while (true) {
                if (params.items.len >= 255) {
                    self.errorAtCurrent("Can't have more than 255 parameters.");
                    return error.ExpectedExpression;
                }

                const param = try self.consume(.identifier, "Expect parameter name.");
                try params.append(self.allocator, param.lexeme);

                if (!self.match(.comma)) break;
            }
        }

        _ = try self.consume(.right_paren, "Expect ')' after parameters.");
        _ = try self.consume(.left_brace, "Expect '{' before function body.");
        const body = try self.blockStatements();
        return try self.makeStmt(.{ .function = .{ .name = name.lexeme, .params = params.items, .body = body } });
    }

    fn classDeclaration(self: *Parser) ParseError!*ast.Stmt {
        const name = try self.consume(.identifier, "Expect class name.");
        var superclass: ?[]const u8 = null;

        if (self.match(.less)) {
            const superclass_name = try self.consume(.identifier, "Expect superclass name.");
            superclass = superclass_name.lexeme;
        }

        _ = try self.consume(.left_brace, "Expect '{' before class body.");

        var methods: std.ArrayListUnmanaged(*ast.Stmt) = .{
            .items = &[_]*ast.Stmt{},
            .capacity = 0,
        };

        while (!self.check(.right_brace) and !self.isAtEnd()) {
            try methods.append(self.allocator, try self.functionDeclaration());
        }

        _ = try self.consume(.right_brace, "Expect '}' after class body.");
        return try self.makeStmt(.{ .class_decl = .{ .name = name.lexeme, .superclass = superclass, .methods = methods.items } });
    }

    fn returnStatement(self: *Parser) ParseError!*ast.Stmt {
        const keyword = self.previous();
        var value: ?*ast.Expr = null;
        if (!self.check(.semicolon)) {
            value = try self.expression();
        }

        _ = try self.consume(.semicolon, "Expect ';' after return value.");
        return try self.makeStmt(.{ .return_stmt = .{ .keyword = keyword, .value = value } });
    }

    fn varDeclaration(self: *Parser) ParseError!*ast.Stmt {
        const name = try self.consume(.identifier, "Expect variable name.");

        var initializer: ?*ast.Expr = null;
        if (self.match(.equal)) {
            initializer = try self.expression();
        }

        _ = try self.consume(.semicolon, "Expect ';' after variable declaration.");
        return try self.makeStmt(.{ .var_decl = .{ .name = name.lexeme, .initializer = initializer } });
    }

    fn moduleDeclaration(self: *Parser) ParseError!*ast.Stmt {
        const name = try self.consume(.identifier, "Expect module name.");
        _ = try self.consume(.semicolon, "Expect ';' after module declaration.");
        return try self.makeStmt(.{ .module_decl = .{ .name = name.lexeme } });
    }

    fn importStatement(self: *Parser) ParseError!*ast.Stmt {
        const path_token = try self.consume(.string, "Expect string literal after 'import'.");
        var alias: ?[]const u8 = null;

        if (self.match(.as_kw)) {
            const alias_token = try self.consume(.identifier, "Expect alias name after 'as'.");
            alias = alias_token.lexeme;
        }

        _ = try self.consume(.semicolon, "Expect ';' after import statement.");
        const path_literal = path_token.literal orelse return error.ExpectedExpression;
        return switch (path_literal) {
            .string => |import_path| try self.makeStmt(.{ .import_stmt = .{ .path = import_path, .alias = alias } }),
            else => error.ExpectedExpression,
        };
    }

    fn forStatement(self: *Parser) ParseError!*ast.Stmt {
        _ = try self.consume(.left_paren, "Expect '(' after 'for'.");

        var initializer: ?*ast.Stmt = null;
        if (self.match(.semicolon)) {
            initializer = null;
        } else if (self.match(.var_kw)) {
            initializer = try self.varDeclaration();
        } else {
            const value = try self.expression();
            _ = try self.consume(.semicolon, "Expect ';' after loop initializer.");
            initializer = try self.makeStmt(.{ .expression = value });
        }

        var condition: ?*ast.Expr = null;
        if (!self.check(.semicolon)) {
            condition = try self.expression();
        }
        _ = try self.consume(.semicolon, "Expect ';' after loop condition.");

        var increment: ?*ast.Expr = null;
        if (!self.check(.right_paren)) {
            increment = try self.expression();
        }
        _ = try self.consume(.right_paren, "Expect ')' after for clauses.");

        var body = try self.statement();

        if (increment) |increment_expr| {
            var statements: std.ArrayListUnmanaged(*ast.Stmt) = .{
                .items = &[_]*ast.Stmt{},
                .capacity = 0,
            };
            try statements.append(self.allocator, body);
            try statements.append(self.allocator, try self.makeStmt(.{ .expression = increment_expr }));
            body = try self.makeStmt(.{ .block = statements.items });
        }

        const while_condition = condition orelse try self.makeExpr(.{ .literal = .{ .bool = true } });
        var while_stmt = try self.makeStmt(.{ .while_stmt = .{
            .condition = while_condition,
            .body = body,
        } });

        if (initializer) |init_stmt| {
            var statements: std.ArrayListUnmanaged(*ast.Stmt) = .{
                .items = &[_]*ast.Stmt{},
                .capacity = 0,
            };
            try statements.append(self.allocator, init_stmt);
            try statements.append(self.allocator, while_stmt);
            while_stmt = try self.makeStmt(.{ .block = statements.items });
        }

        return while_stmt;
    }

    fn ifStatement(self: *Parser) ParseError!*ast.Stmt {
        _ = try self.consume(.left_paren, "Expect '(' after 'if'.");
        const condition = try self.expression();
        _ = try self.consume(.right_paren, "Expect ')' after if condition.");

        const then_branch = try self.statement();
        var else_branch: ?*ast.Stmt = null;
        if (self.match(.else_kw)) {
            else_branch = try self.statement();
        }

        return try self.makeStmt(.{ .if_stmt = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } });
    }

    fn whileStatement(self: *Parser) ParseError!*ast.Stmt {
        _ = try self.consume(.left_paren, "Expect '(' after 'while'.");
        const condition = try self.expression();
        _ = try self.consume(.right_paren, "Expect ')' after while condition.");

        const body = try self.statement();
        return try self.makeStmt(.{ .while_stmt = .{
            .condition = condition,
            .body = body,
        } });
    }

    fn blockStatement(self: *Parser) ParseError!*ast.Stmt {
        return try self.makeStmt(.{ .block = try self.blockStatements() });
    }

    fn blockStatements(self: *Parser) ParseError![]const *ast.Stmt {
        var statements: std.ArrayListUnmanaged(*ast.Stmt) = .{
            .items = &[_]*ast.Stmt{},
            .capacity = 0,
        };

        while (!self.check(.right_brace) and !self.isAtEnd()) {
            try statements.append(self.allocator, try self.statement());
        }

        _ = try self.consume(.right_brace, "Expect '}' after block.");
        return statements.items;
    }

    fn errorAtCurrent(self: *Parser, message: []const u8) void {
        const current = self.peek();
        self.errorAtToken(current, message);
    }

    fn errorAtToken(self: *Parser, current: token.Token, message: []const u8) void {
        _ = self;
        std.debug.print("[line {d}] Error at '{s}': {s}\n", .{ current.line, current.lexeme, message });
    }

    fn makeExpr(self: *Parser, expr: ast.Expr) !*ast.Expr {
        const node = try self.allocator.create(ast.Expr);
        node.* = expr;
        return node;
    }

    fn makeStmt(self: *Parser, stmt: ast.Stmt) !*ast.Stmt {
        const node = try self.allocator.create(ast.Stmt);
        node.* = stmt;
        return node;
    }

    fn match(self: *Parser, typ: token.TokenType) bool {
        if (!self.check(typ)) return false;
        _ = self.advance();
        return true;
    }

    fn check(self: *Parser, typ: token.TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().typ == typ;
    }

    fn advance(self: *Parser) token.Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    fn isAtEnd(self: *Parser) bool {
        return self.peek().typ == .eof;
    }

    fn peek(self: *Parser) token.Token {
        return self.tokens[self.current];
    }

    fn previous(self: *Parser) token.Token {
        return self.tokens[self.current - 1];
    }
};

test "parser handles print statement" {
    const source = "print 1 + 2 * 3;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try std.testing.expectEqual(@as(usize, 1), statements.items.len);
}

test "parser handles variable declarations and assignment" {
    const source = "var a = 1; a = a + 2;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
    try std.testing.expect(switch (statements.items[0].*) {
        .var_decl => true,
        else => false,
    });
}

test "parser handles functions and calls" {
    const source = "fun add(a, b) { return a + b; } print add(1, 2);";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
    try std.testing.expect(switch (statements.items[0].*) {
        .function => true,
        else => false,
    });
}

test "parser handles logical operators" {
    const source = "print true or false; print false and true;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
}

test "parser handles class declarations and property access" {
    const source = "class Foo < Bar { init(v) { this.v = v; } getV() { return this.v; } } var foo = Foo(3); print foo.getV();";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try std.testing.expect(statements.items.len >= 2);
}

test "parser handles control flow" {
    const source = "if (true) print 1; else print 2; while (false) print 3;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
}
