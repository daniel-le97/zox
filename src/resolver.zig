const std = @import("std");
const ast = @import("ast.zig");

pub const ResolveError = error{OutOfMemory};

const ScopeKind = enum {
    global,
    function_body,
    block,
    method_this,
    method_super,
};

const Scope = struct {
    names: std.StringHashMapUnmanaged(usize) = .{},
    next_slot: usize = 0,
    kind: ScopeKind,
    owner_function: ?*ast.FunctionStmt = null,
};

pub fn resolve(allocator: std.mem.Allocator, statements: []const *ast.Stmt) ResolveError!void {
    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    try resolver.resolveStatements(statements);
}

const Resolver = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayListUnmanaged(Scope) = .{ .items = &[_]Scope{}, .capacity = 0 },
    current_function: ?*ast.FunctionStmt = null,

    fn init(allocator: std.mem.Allocator) Resolver {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Resolver) void {
        for (self.scopes.items) |*scope| {
            scope.names.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
    }

    fn resolveStatements(self: *Resolver, statements: []const *ast.Stmt) ResolveError!void {
        try self.beginScope(.global, null);
        defer self.endScope();

        for (statements) |statement| {
            try self.resolveStmt(statement);
        }
    }

    fn beginScope(self: *Resolver, kind: ScopeKind, owner_function: ?*ast.FunctionStmt) ResolveError!void {
        try self.scopes.append(self.allocator, .{ .kind = kind, .owner_function = owner_function });
    }

    fn endScope(self: *Resolver) void {
        var scope = self.scopes.items[self.scopes.items.len - 1];
        self.scopes.items.len -= 1;
        scope.names.deinit(self.allocator);
    }

    fn currentScope(self: *Resolver) *Scope {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    fn declare(self: *Resolver, name: []const u8) ResolveError!usize {
        const scope = self.currentScope();
        const slot = scope.next_slot;
        scope.next_slot += 1;
        try scope.names.put(self.allocator, name, slot);
        return slot;
    }

    fn resolveStmt(self: *Resolver, statement: *const ast.Stmt) ResolveError!void {
        const mutable_statement = @constCast(statement);
        switch (mutable_statement.*) {
            .expression => |expr| try self.resolveExpr(expr),
            .print => |expr| try self.resolveExpr(expr),
            .var_decl => |*var_decl| {
                var_decl.slot = try self.declare(var_decl.name);
                if (var_decl.initializer) |initializer| {
                    try self.resolveExpr(initializer);
                }
            },
            .module_decl => {},
            .import_stmt => |*import_stmt| {
                if (import_stmt.alias) |alias| {
                    import_stmt.slot = try self.declare(alias);
                }
            },
            .function => |*function_stmt| {
                function_stmt.slot = try self.declare(function_stmt.name);
                try self.resolveFunction(function_stmt, false);
            },
            .class_decl => |*class_decl| {
                class_decl.slot = try self.declare(class_decl.name);

                if (class_decl.superclass) |superclass_name| {
                    class_decl.superclass_resolution = try self.resolveReference(superclass_name);
                }

                if (class_decl.superclass != null) {
                    try self.beginScope(.method_super, null);
                    defer self.endScope();
                    _ = try self.declare("super");

                    try self.beginScope(.method_this, null);
                    defer self.endScope();
                    _ = try self.declare("this");

                    for (class_decl.methods) |method| {
                        switch (method.*) {
                            .function => |*method_stmt| try self.resolveFunction(method_stmt, true),
                            else => {},
                        }
                    }
                } else {
                    try self.beginScope(.method_this, null);
                    defer self.endScope();
                    _ = try self.declare("this");

                    for (class_decl.methods) |method| {
                        switch (method.*) {
                            .function => |*method_stmt| try self.resolveFunction(method_stmt, true),
                            else => {},
                        }
                    }
                }
            },
            .return_stmt => |return_stmt| {
                if (return_stmt.value) |value| {
                    try self.resolveExpr(value);
                }
            },
            .break_stmt, .continue_stmt => {},
            .for_stmt => |for_stmt| {
                if (for_stmt.initializer) |initializer| {
                    try self.resolveStmt(initializer);
                }
                if (for_stmt.condition) |condition| {
                    try self.resolveExpr(condition);
                }
                try self.resolveStmt(for_stmt.body);
                if (for_stmt.increment) |increment| {
                    try self.resolveExpr(increment);
                }
            },
            .block => |statements| {
                try self.beginScope(.block, self.current_function);
                defer self.endScope();
                for (statements) |inner_statement| {
                    try self.resolveStmt(inner_statement);
                }
            },
            .if_stmt => |if_stmt| {
                try self.resolveExpr(if_stmt.condition);
                try self.resolveStmt(if_stmt.then_branch);
                if (if_stmt.else_branch) |else_branch| {
                    try self.resolveStmt(else_branch);
                }
            },
            .while_stmt => |while_stmt| {
                try self.resolveExpr(while_stmt.condition);
                try self.resolveStmt(while_stmt.body);
            },
        }
    }

    fn resolveFunction(self: *Resolver, function_stmt: *ast.FunctionStmt, is_method: bool) ResolveError!void {
        const previous_function = self.current_function;
        self.current_function = function_stmt;
        defer self.current_function = previous_function;

        if (is_method) {
            // `this` and optional `super` are provided by surrounding synthetic scopes.
        }

        try self.beginScope(.function_body, function_stmt);
        defer self.endScope();

        for (function_stmt.params) |param| {
            _ = try self.declare(param);
        }

        for (function_stmt.body) |statement| {
            try self.resolveStmt(statement);
        }
    }

    fn resolveExpr(self: *Resolver, expr: *const ast.Expr) ResolveError!void {
        const mutable_expr = @constCast(expr);
        switch (mutable_expr.*) {
            .literal => {},
            .grouping => |inner| try self.resolveExpr(inner),
            .unary => |unary| try self.resolveExpr(unary.right),
            .binary => |binary| {
                try self.resolveExpr(binary.left);
                try self.resolveExpr(binary.right);
            },
            .logical => |logical| {
                try self.resolveExpr(logical.left);
                try self.resolveExpr(logical.right);
            },
            .variable => |*variable| {
                variable.resolved = try self.resolveReference(variable.name);
            },
            .assign => |*assignment| {
                try self.resolveExpr(assignment.value);
                assignment.resolved = try self.resolveReference(assignment.name);
            },
            .call => |call| {
                try self.resolveExpr(call.callee);
                for (call.arguments) |argument| {
                    try self.resolveExpr(argument);
                }
            },
            .get => |get_expr| try self.resolveExpr(get_expr.object),
            .set => |set_expr| {
                try self.resolveExpr(set_expr.object);
                try self.resolveExpr(set_expr.value);
            },
            .super_expr => |super_expr| {
                _ = super_expr;
            },
        }
    }

    fn resolveReference(self: *Resolver, name: []const u8) ResolveError!?ast.ResolvedLocal {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            const scope = &self.scopes.items[index];
            if (scope.names.get(name)) |slot| {
                if (scope.kind == .function_body and scope.owner_function != null) {
                    const owner_function = scope.owner_function.?;
                    if (owner_function != self.current_function) {
                        owner_function.captures_environment = true;
                    }
                }

                return .{ .depth = self.scopes.items.len - 1 - index, .slot = slot };
            }
        }

        return null;
    }
};
