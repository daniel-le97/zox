const std = @import("std");
const ast = @import("ast.zig");
const native_stdlib = @import("native_stdlib.zig");
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const token = @import("token.zig");

pub const RuntimeError = runtime.RuntimeError;
const BuiltinFunction = runtime.BuiltinFunction;

const ModuleCache = struct {
    modules: std.StringHashMapUnmanaged(*LoxModule) = .{},
    loading: std.StringHashMapUnmanaged(void) = .{},

    fn get(self: *ModuleCache, path: []const u8) ?*LoxModule {
        return self.modules.get(path);
    }

    fn put(self: *ModuleCache, allocator: std.mem.Allocator, path: []const u8, module_object: *LoxModule) !void {
        try self.modules.put(allocator, path, module_object);
    }

    fn beginLoad(self: *ModuleCache, allocator: std.mem.Allocator, path: []const u8) !bool {
        if (self.modules.contains(path)) return false;
        if (self.loading.contains(path)) return error.ImportCycle;
        try self.loading.put(allocator, path, {});
        return true;
    }

    fn endLoad(self: *ModuleCache, allocator: std.mem.Allocator, path: []const u8) void {
        _ = allocator;
        _ = self.loading.remove(path);
    }
};

const ExecutionContext = struct {
    io: ?std.Io,
    source_path: ?[]const u8,
    module_cache: *ModuleCache,
    module_name: ?[]const u8,
};

pub fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});
    const source = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(source);

    const read = try cwd.readFile(io, path, source);
    try runSourceWithPath(allocator, read, path, io);
}

pub fn runSource(allocator: std.mem.Allocator, source: []const u8) !void {
    try runSourceWithPath(allocator, source, null, null);
}

pub fn runSourceWithPath(allocator: std.mem.Allocator, source: []const u8, source_path: ?[]const u8, io: ?std.Io) !void {
    const tokens = try @import("scanner.zig").scanTokens(allocator, source);
    var parser = @import("parser.zig").Parser.init(allocator, tokens.items);
    const statements = try parser.parse();

    var module_cache = ModuleCache{};
    var interpreter = try Interpreter.init(allocator, .{
        .io = io,
        .source_path = source_path,
        .module_cache = &module_cache,
        .module_name = defaultModuleName(source_path),
    });

    for (statements.items) |statement| {
        try interpreter.execute(statement);
    }
}

pub fn execute(allocator: std.mem.Allocator, statements: []const *ast.Stmt) !void {
    var module_cache = ModuleCache{};
    var interpreter = try Interpreter.init(allocator, .{
        .io = null,
        .source_path = null,
        .module_cache = &module_cache,
        .module_name = null,
    });
    for (statements) |statement| {
        try interpreter.execute(statement);
    }
}

const Interpreter = struct {
    allocator: std.mem.Allocator,
    globals: *Environment,
    environment: *Environment,
    call_depth: usize = 0,
    active_loops: std.ArrayListUnmanaged(LoopContext) = .{ .items = &[_]LoopContext{}, .capacity = 0 },
    return_value: ?ast.LiteralValue = null,
    io: ?std.Io,
    source_path: ?[]const u8,
    module_name: ?[]const u8,
    module_cache: *ModuleCache,

    fn init(allocator: std.mem.Allocator, context: ExecutionContext) !Interpreter {
        const globals = try allocator.create(Environment);
        globals.* = .{};
        var interpreter: Interpreter = .{
            .allocator = allocator,
            .globals = globals,
            .environment = globals,
            .io = context.io,
            .source_path = context.source_path,
            .module_name = context.module_name,
            .module_cache = context.module_cache,
        };
        try interpreter.installBuiltins();
        return interpreter;
    }

    fn installBuiltins(self: *Interpreter) !void {
        try native_stdlib.install(self);
    }

    fn defineBuiltin(self: *Interpreter, name: []const u8, arity: ?usize, callback: runtime.BuiltinCallback) !void {
        const builtin = try self.allocator.create(BuiltinFunction);
        builtin.* = .{ .name = name, .arity = arity, .callback = callback };
        try self.globals.define(self.allocator, name, .{ .native_function = @ptrCast(builtin) });
    }

    fn executeSource(self: *Interpreter, source: []const u8) !void {
        const tokens = try @import("scanner.zig").scanTokens(self.allocator, source);
        var parser = @import("parser.zig").Parser.init(self.allocator, tokens.items);
        const statements = try parser.parse();

        for (statements.items) |statement| {
            try self.execute(statement);
        }
    }

    fn execute(self: *Interpreter, statement: *const ast.Stmt) RuntimeError!void {
        switch (statement.*) {
            .expression => |expr| {
                _ = try self.evaluate(expr);
            },
            .print => |expr| {
                const result = try self.evaluate(expr);
                try self.printValue(result);
            },
            .var_decl => |var_decl| {
                const value = if (var_decl.initializer) |initializer|
                    try self.evaluate(initializer)
                else
                    .nil;
                try self.environment.define(self.allocator, var_decl.name, value);
            },
            .module_decl => |module_decl| {
                self.module_name = module_decl.name;
            },
            .import_stmt => |import_stmt| {
                const module_value = try self.loadModule(import_stmt.path);
                const module_object = asModule(module_value) orelse return error.InvalidOperand;
                const binding_name = import_stmt.alias orelse module_object.name;
                try self.environment.define(self.allocator, binding_name, module_value);
            },
            .function => |function_stmt| {
                const function_object = try self.allocator.create(LoxFunction);
                function_object.* = .{
                    .name = function_stmt.name,
                    .params = function_stmt.params,
                    .body = function_stmt.body,
                    .closure = self.environment,
                    .is_initializer = std.mem.eql(u8, function_stmt.name, "init"),
                };
                try self.environment.define(self.allocator, function_stmt.name, .{ .function = @ptrCast(function_object) });
            },
            .class_decl => |class_decl| {
                try self.environment.define(self.allocator, class_decl.name, .nil);

                var superclass: ?*LoxClass = null;
                if (class_decl.superclass) |superclass_name| {
                    const superclass_value = self.environment.get(superclass_name) orelse return error.UndefinedVariable;
                    superclass = asClass(superclass_value) orelse return error.InvalidOperand;
                }

                var method_environment = self.environment;
                if (superclass) |superclass_class| {
                    const super_env = try self.allocator.create(Environment);
                    super_env.* = .{ .enclosing = self.environment };
                    try super_env.define(self.allocator, "super", .{ .class = @ptrCast(superclass_class) });
                    method_environment = super_env;
                }

                const class_object = try self.allocator.create(LoxClass);
                class_object.* = .{ .name = class_decl.name, .superclass = superclass };
                try class_object.initMethods(self, method_environment, class_decl.methods);
                try self.environment.define(self.allocator, class_decl.name, .{ .class = @ptrCast(class_object) });
            },
            .return_stmt => |return_stmt| {
                if (self.call_depth == 0) return error.InvalidReturn;
                self.return_value = if (return_stmt.value) |expression|
                    try self.evaluate(expression)
                else
                    .nil;
                return error.ReturnSignal;
            },
            .break_stmt => {
                if (!self.canSignalLoop()) return error.InvalidBreak;
                return error.BreakSignal;
            },
            .continue_stmt => {
                if (!self.canSignalLoop()) return error.InvalidContinue;
                return error.ContinueSignal;
            },
            .for_stmt => |for_stmt| {
                try self.executeFor(for_stmt);
            },
            .block => |statements| {
                const environment = try self.allocator.create(Environment);
                environment.* = .{ .enclosing = self.environment };
                try self.executeBlock(statements, environment);
            },
            .if_stmt => |if_stmt| {
                if (isTruthy(try self.evaluate(if_stmt.condition))) {
                    try self.execute(if_stmt.then_branch);
                } else if (if_stmt.else_branch) |else_branch| {
                    try self.execute(else_branch);
                }
            },
            .while_stmt => |while_stmt| {
                try self.pushLoop();
                defer self.popLoop();

                while (isTruthy(try self.evaluate(while_stmt.condition))) {
                    self.execute(while_stmt.body) catch |err| switch (err) {
                        error.BreakSignal => break,
                        error.ContinueSignal => continue,
                        else => return err,
                    };
                }
            },
        }
    }

    fn evaluate(self: *Interpreter, expr: *const ast.Expr) RuntimeError!ast.LiteralValue {
        return switch (expr.*) {
            .literal => |literal| literal,
            .grouping => |inner| self.evaluate(inner),
            .unary => |unary| try self.evalUnary(unary),
            .binary => |binary| try self.evalBinary(binary),
            .logical => |logical| try self.evalLogical(logical),
            .variable => |name| try self.getVariable(name),
            .assign => |assignment| try self.evalAssign(assignment),
            .call => |call| try self.evalCall(call),
            .get => |get_expr| try self.evalGet(get_expr),
            .set => |set_expr| try self.evalSet(set_expr),
            .super_expr => |super_expr| try self.evalSuper(super_expr),
        };
    }

    fn loadModule(self: *Interpreter, import_path: []const u8) RuntimeError!ast.LiteralValue {
        if (self.io == null) return error.ImportUnavailable;

        const resolved_path = try self.resolveImportPath(import_path);
        if (self.module_cache.get(resolved_path)) |cached_module| {
            return .{ .module = @ptrCast(cached_module) };
        }

        _ = try self.module_cache.beginLoad(self.allocator, resolved_path);
        defer self.module_cache.endLoad(self.allocator, resolved_path);

        if (stdlib.getSource(resolved_path)) |source| {
            return try self.instantiateModule(resolved_path, source);
        }

        const cwd = std.Io.Dir.cwd();
        const stat = cwd.statFile(self.io.?, resolved_path, .{}) catch return error.ImportFailed;
        const source = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(source);

        const read = cwd.readFile(self.io.?, resolved_path, source) catch return error.ImportFailed;
        return try self.instantiateModule(resolved_path, read);
    }

    fn instantiateModule(self: *Interpreter, resolved_path: []const u8, source: []const u8) RuntimeError!ast.LiteralValue {
        var child = try Interpreter.init(self.allocator, .{
            .io = self.io,
            .source_path = resolved_path,
            .module_cache = self.module_cache,
            .module_name = defaultModuleName(resolved_path),
        });
        child.executeSource(source) catch |err| switch (err) {
            error.ImportCycle => return error.ImportCycle,
            else => return error.ImportFailed,
        };

        const module_object = try self.allocator.create(LoxModule);
        module_object.* = .{ .name = child.module_name orelse defaultModuleName(resolved_path) orelse resolved_path, .exports = .{} };
        try module_object.captureExports(self.allocator, child.globals);
        try self.module_cache.put(self.allocator, resolved_path, module_object);
        return .{ .module = @ptrCast(module_object) };
    }

    fn resolveImportPath(self: *Interpreter, import_path: []const u8) RuntimeError![]const u8 {
        if (isStdlibPath(import_path)) {
            return import_path;
        }

        if (std.fs.path.isAbsolute(import_path)) {
            return import_path;
        }

        const base_dir = if (self.source_path) |source_path| pathDirname(source_path) else ".";
        return std.fs.path.resolve(self.allocator, &.{ base_dir, import_path }) catch return error.OutOfMemory;
    }

    fn evalSuper(self: *Interpreter, super_expr: ast.SuperExpr) RuntimeError!ast.LiteralValue {
        const superclass_value = self.environment.get("super") orelse return error.UndefinedVariable;
        const superclass = asClass(superclass_value) orelse return error.InvalidOperand;

        const object_value = self.environment.get("this") orelse return error.UndefinedVariable;
        const instance = asInstance(object_value) orelse return error.InvalidOperand;

        const method = superclass.getMethod(super_expr.method) orelse return error.UndefinedVariable;
        return .{ .function = @ptrCast(try method.bind(self, instance)) };
    }

    fn evalGet(self: *Interpreter, get_expr: ast.Get) RuntimeError!ast.LiteralValue {
        const object_value = try self.evaluate(get_expr.object);
        if (asInstance(object_value)) |instance| {
            if (instance.getField(get_expr.name)) |field| return field;
            if (instance.class.getMethod(get_expr.name)) |method| {
                return .{ .function = @ptrCast(try method.bind(self, instance)) };
            }
            return error.UndefinedVariable;
        }

        if (asModule(object_value)) |module_object| {
            if (module_object.getField(get_expr.name)) |field| return field;
            return error.UndefinedVariable;
        }

        return error.UndefinedVariable;
    }

    fn executeFor(self: *Interpreter, for_stmt: ast.ForStmt) RuntimeError!void {
        if (for_stmt.initializer) |initializer| {
            try self.execute(initializer);
        }

        try self.pushLoop();
        defer self.popLoop();

        while (true) {
            if (for_stmt.condition) |condition| {
                if (!isTruthy(try self.evaluate(condition))) break;
            }

            var should_continue = false;
            self.execute(for_stmt.body) catch |err| switch (err) {
                error.BreakSignal => break,
                error.ContinueSignal => should_continue = true,
                else => return err,
            };

            if (for_stmt.increment) |increment| {
                _ = try self.evaluate(increment);
            }

            if (should_continue) continue;
        }
    }

    fn pushLoop(self: *Interpreter) RuntimeError!void {
        try self.active_loops.append(self.allocator, .{ .call_depth = self.call_depth });
    }

    fn popLoop(self: *Interpreter) void {
        self.active_loops.items.len -= 1;
    }

    fn canSignalLoop(self: *Interpreter) bool {
        if (self.active_loops.items.len == 0) return false;
        return self.active_loops.items[self.active_loops.items.len - 1].call_depth == self.call_depth;
    }

    fn evalSet(self: *Interpreter, set_expr: ast.Set) RuntimeError!ast.LiteralValue {
        const object_value = try self.evaluate(set_expr.object);
        const instance = asInstance(object_value) orelse return error.InvalidOperand;
        const value = try self.evaluate(set_expr.value);
        try instance.setField(self.allocator, set_expr.name, value);
        return value;
    }

    fn evalCall(self: *Interpreter, call: ast.Call) RuntimeError!ast.LiteralValue {
        const callee = try self.evaluate(call.callee);

        var arguments: std.ArrayListUnmanaged(ast.LiteralValue) = .{
            .items = &[_]ast.LiteralValue{},
            .capacity = 0,
        };
        for (call.arguments) |argument| {
            try arguments.append(self.allocator, try self.evaluate(argument));
        }

        return switch (callee) {
            .function => |function_object| try self.callFunction(@as(*LoxFunction, @ptrCast(@alignCast(function_object))), arguments.items),
            .native_function => |function_object| try self.callBuiltin(@as(*BuiltinFunction, @ptrCast(@alignCast(function_object))), arguments.items),
            .class => |class_object| try self.instantiate(@as(*LoxClass, @ptrCast(@alignCast(class_object))), arguments.items),
            .module => error.NotCallable,
            else => error.NotCallable,
        };
    }

    fn callBuiltin(self: *Interpreter, builtin: *BuiltinFunction, arguments: []const ast.LiteralValue) RuntimeError!ast.LiteralValue {
        if (builtin.arity) |arity| {
            if (arity != arguments.len) return error.WrongArity;
        }

        return builtin.callback(.{ .allocator = self.allocator, .io = self.io }, arguments);
    }

    fn instantiate(self: *Interpreter, class_object: *LoxClass, arguments: []const ast.LiteralValue) RuntimeError!ast.LiteralValue {
        const instance = try self.allocator.create(LoxInstance);
        instance.* = .{ .class = class_object };

        if (class_object.getMethod("init")) |initializer| {
            const bound_initializer = try initializer.bind(self, instance);
            _ = try self.callFunction(bound_initializer, arguments);
        } else if (arguments.len != 0) {
            return error.WrongArity;
        }

        return .{ .instance = @ptrCast(instance) };
    }

    fn callFunction(self: *Interpreter, function_object: *LoxFunction, arguments: []const ast.LiteralValue) RuntimeError!ast.LiteralValue {
        if (function_object.params.len != arguments.len) return error.WrongArity;

        const environment = try self.allocator.create(Environment);
        environment.* = .{ .enclosing = function_object.closure };
        for (function_object.params, arguments) |param, argument| {
            try environment.define(self.allocator, param, argument);
        }

        const previous_return_value = self.return_value;
        self.return_value = null;
        self.call_depth += 1;
        defer {
            self.call_depth -= 1;
            self.return_value = previous_return_value;
        }

        self.executeBlock(function_object.body, environment) catch |err| switch (err) {
            error.ReturnSignal => {},
            else => return err,
        };

        if (function_object.is_initializer) return function_object.closure.getAt("this") orelse .nil;
        return self.return_value orelse .nil;
    }

    fn getVariable(self: *Interpreter, name: []const u8) RuntimeError!ast.LiteralValue {
        return self.environment.get(name) orelse error.UndefinedVariable;
    }

    fn evalAssign(self: *Interpreter, assignment: ast.Assign) RuntimeError!ast.LiteralValue {
        const assigned_value = try self.evaluate(assignment.value);
        if (!try self.environment.assign(self.allocator, assignment.name, assigned_value)) {
            return error.UndefinedVariable;
        }

        return assigned_value;
    }

    fn executeBlock(self: *Interpreter, statements: []const *ast.Stmt, environment: *Environment) RuntimeError!void {
        const previous = self.environment;
        self.environment = environment;
        defer self.environment = previous;

        for (statements) |inner_statement| {
            try self.execute(inner_statement);
        }
    }

    fn evalUnary(self: *Interpreter, unary: ast.Unary) RuntimeError!ast.LiteralValue {
        const right = try self.evaluate(unary.right);

        switch (unary.operator) {
            .minus => {
                return .{ .number = try self.expectNumber(right) * -1 };
            },
            .bang => {
                return .{ .bool = !isTruthy(right) };
            },
            else => return error.InvalidOperand,
        }
    }

    fn evalBinary(self: *Interpreter, binary: ast.Binary) RuntimeError!ast.LiteralValue {
        const left = try self.evaluate(binary.left);
        const right = try self.evaluate(binary.right);

        switch (binary.operator) {
            .plus => return try self.add(left, right),
            .minus => return .{ .number = try self.expectNumber(left) - try self.expectNumber(right) },
            .star => return .{ .number = try self.expectNumber(left) * try self.expectNumber(right) },
            .slash => {
                const denominator = try self.expectNumber(right);
                if (denominator == 0) return error.DivisionByZero;
                return .{ .number = try self.expectNumber(left) / denominator };
            },
            .greater => return .{ .bool = try self.expectNumber(left) > try self.expectNumber(right) },
            .greater_equal => return .{ .bool = try self.expectNumber(left) >= try self.expectNumber(right) },
            .less => return .{ .bool = try self.expectNumber(left) < try self.expectNumber(right) },
            .less_equal => return .{ .bool = try self.expectNumber(left) <= try self.expectNumber(right) },
            .equal_equal => return .{ .bool = valuesEqual(left, right) },
            .bang_equal => return .{ .bool = !valuesEqual(left, right) },
            else => return error.InvalidOperand,
        }
    }

    fn evalLogical(self: *Interpreter, logical: ast.Logical) RuntimeError!ast.LiteralValue {
        const left = try self.evaluate(logical.left);

        switch (logical.operator) {
            .or_kw => {
                if (isTruthy(left)) return left;
            },
            .and_kw => {
                if (!isTruthy(left)) return left;
            },
            else => return error.InvalidOperand,
        }

        return self.evaluate(logical.right);
    }

    fn add(self: *Interpreter, left: ast.LiteralValue, right: ast.LiteralValue) RuntimeError!ast.LiteralValue {
        return switch (left) {
            .number => |lhs| switch (right) {
                .number => |rhs| .{ .number = lhs + rhs },
                else => error.InvalidOperand,
            },
            .string => |lhs| switch (right) {
                .string => |rhs| .{ .string = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ lhs, rhs }) },
                else => error.InvalidOperand,
            },
            else => error.InvalidOperand,
        };
    }

    fn expectNumber(self: *Interpreter, number_value: ast.LiteralValue) RuntimeError!f64 {
        _ = self;
        return switch (number_value) {
            .number => |n| n,
            else => error.InvalidOperand,
        };
    }

    fn printValue(self: *Interpreter, printed_value: ast.LiteralValue) !void {
        _ = self;
        switch (printed_value) {
            .nil => std.debug.print("nil\n", .{}),
            .bool => |b| std.debug.print("{s}\n", .{if (b) "true" else "false"}),
            .number => |n| std.debug.print("{d}\n", .{n}),
            .string => |s| std.debug.print("{s}\n", .{s}),
            .function => |function_object| std.debug.print("<fn {s}>\n", .{@as(*LoxFunction, @ptrCast(@alignCast(function_object))).name}),
            .native_function => |function_object| std.debug.print("<builtin {s}>\n", .{@as(*BuiltinFunction, @ptrCast(@alignCast(function_object))).name}),
            .class => |class_object| std.debug.print("<class {s}>\n", .{@as(*LoxClass, @ptrCast(@alignCast(class_object))).name}),
            .instance => |instance_object| std.debug.print("<{s} instance>\n", .{@as(*LoxInstance, @ptrCast(@alignCast(instance_object))).class.name}),
            .module => |module_object| std.debug.print("<module {s}>\n", .{@as(*LoxModule, @ptrCast(@alignCast(module_object))).name}),
        }
    }
};

const LoxModule = struct {
    name: []const u8,
    exports: std.StringHashMapUnmanaged(ast.LiteralValue) = .{},

    fn getField(self: *LoxModule, name: []const u8) ?ast.LiteralValue {
        return self.exports.get(name);
    }

    fn captureExports(self: *LoxModule, allocator: std.mem.Allocator, environment: *Environment) !void {
        self.exports = .{};
        var iterator = environment.values.iterator();
        while (iterator.next()) |entry| {
            try self.exports.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

const LoopContext = struct {
    call_depth: usize,
};

const LoxFunction = struct {
    name: []const u8,
    params: []const []const u8,
    body: []const *ast.Stmt,
    closure: *Environment,
    is_initializer: bool = false,

    fn bind(self: *const LoxFunction, interpreter: *Interpreter, instance: *LoxInstance) RuntimeError!*LoxFunction {
        const environment = try interpreter.allocator.create(Environment);
        environment.* = .{ .enclosing = self.closure };
        try environment.define(interpreter.allocator, "this", .{ .instance = @ptrCast(instance) });

        const bound = try interpreter.allocator.create(LoxFunction);
        bound.* = self.*;
        bound.closure = environment;
        return bound;
    }
};

const LoxClass = struct {
    name: []const u8,
    superclass: ?*LoxClass = null,
    methods: std.StringHashMapUnmanaged(*LoxFunction) = .{},

    fn initMethods(self: *LoxClass, interpreter: *Interpreter, method_environment: *Environment, method_stmts: []const *ast.Stmt) RuntimeError!void {
        for (method_stmts) |stmt| {
            switch (stmt.*) {
                .function => |function_stmt| {
                    const function_object = try interpreter.allocator.create(LoxFunction);
                    function_object.* = .{
                        .name = function_stmt.name,
                        .params = function_stmt.params,
                        .body = function_stmt.body,
                        .closure = method_environment,
                        .is_initializer = std.mem.eql(u8, function_stmt.name, "init"),
                    };
                    try self.methods.put(interpreter.allocator, function_stmt.name, function_object);
                },
                else => return error.InvalidOperand,
            }
        }
    }

    fn getMethod(self: *LoxClass, name: []const u8) ?*LoxFunction {
        if (self.methods.get(name)) |method| return method;
        if (self.superclass) |superclass| return superclass.getMethod(name);
        return null;
    }
};

const LoxInstance = struct {
    class: *LoxClass,
    fields: std.StringHashMapUnmanaged(ast.LiteralValue) = .{},

    fn getField(self: *LoxInstance, name: []const u8) ?ast.LiteralValue {
        return self.fields.get(name);
    }

    fn setField(self: *LoxInstance, allocator: std.mem.Allocator, name: []const u8, value: ast.LiteralValue) !void {
        try self.fields.put(allocator, name, value);
    }
};

const Environment = struct {
    values: std.StringHashMapUnmanaged(ast.LiteralValue) = .{},
    enclosing: ?*Environment = null,

    fn define(self: *Environment, allocator: std.mem.Allocator, name: []const u8, defined_value: ast.LiteralValue) !void {
        try self.values.put(allocator, name, defined_value);
    }

    fn get(self: *Environment, name: []const u8) ?ast.LiteralValue {
        if (self.values.get(name)) |stored_value| return stored_value;
        if (self.enclosing) |enclosing| return enclosing.get(name);
        return null;
    }

    fn getAt(self: *Environment, name: []const u8) ?ast.LiteralValue {
        return self.values.get(name);
    }

    fn assign(self: *Environment, allocator: std.mem.Allocator, name: []const u8, assigned_value: ast.LiteralValue) !bool {
        if (self.values.contains(name)) {
            try self.values.put(allocator, name, assigned_value);
            return true;
        }

        if (self.enclosing) |enclosing| {
            return try enclosing.assign(allocator, name, assigned_value);
        }

        return false;
    }
};

fn isTruthy(truthy_value: ast.LiteralValue) bool {
    return switch (truthy_value) {
        .nil => false,
        .bool => |b| b,
        else => true,
    };
}

fn valuesEqual(left: ast.LiteralValue, right: ast.LiteralValue) bool {
    return switch (left) {
        .nil => switch (right) {
            .nil => true,
            else => false,
        },
        .bool => |lhs| switch (right) {
            .bool => |rhs| lhs == rhs,
            else => false,
        },
        .number => |lhs| switch (right) {
            .number => |rhs| lhs == rhs,
            else => false,
        },
        .string => |lhs| switch (right) {
            .string => |rhs| std.mem.eql(u8, lhs, rhs),
            else => false,
        },
        .function => |lhs| switch (right) {
            .function => |rhs| lhs == rhs,
            else => false,
        },
        .native_function => |lhs| switch (right) {
            .native_function => |rhs| lhs == rhs,
            else => false,
        },
        .class => |lhs| switch (right) {
            .class => |rhs| lhs == rhs,
            else => false,
        },
        .instance => |lhs| switch (right) {
            .instance => |rhs| lhs == rhs,
            else => false,
        },
        .module => |lhs| switch (right) {
            .module => |rhs| lhs == rhs,
            else => false,
        },
    };
}

fn asInstance(value: ast.LiteralValue) ?*LoxInstance {
    return switch (value) {
        .instance => |instance_object| @as(*LoxInstance, @ptrCast(@alignCast(instance_object))),
        else => null,
    };
}

fn asClass(value: ast.LiteralValue) ?*LoxClass {
    return switch (value) {
        .class => |class_object| @as(*LoxClass, @ptrCast(@alignCast(class_object))),
        else => null,
    };
}

fn asModule(value: ast.LiteralValue) ?*LoxModule {
    return switch (value) {
        .module => |module_object| @as(*LoxModule, @ptrCast(@alignCast(module_object))),
        else => null,
    };
}

fn defaultModuleName(source_path: ?[]const u8) ?[]const u8 {
    const path = source_path orelse return null;
    return pathStem(path);
}

fn isStdlibPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "std/");
}

fn pathStem(path: []const u8) []const u8 {
    const separator_index = lastPathSeparator(path) orelse return if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot_index| path[0..dot_index] else path;
    const filename = path[separator_index + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_index| {
        return filename[0..dot_index];
    }
    return filename;
}

fn pathDirname(path: []const u8) []const u8 {
    const separator_index = lastPathSeparator(path) orelse return ".";
    return path[0..separator_index];
}

fn lastPathSeparator(path: []const u8) ?usize {
    var index: usize = path.len;
    while (index > 0) {
        index -= 1;
        if (path[index] == '/' or path[index] == '\\') return index;
    }
    return null;
}

test "interpreter evaluates arithmetic" {
    const source = "print (1 + 2) * 3;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = @import("parser.zig").Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try execute(arena.allocator(), statements.items);
}

test "interpreter handles variable declarations and assignment" {
    const source = "var a = 1; a = a + 2; print a;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = @import("parser.zig").Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try execute(arena.allocator(), statements.items);
}

test "interpreter handles control flow" {
    const source = "var a = 0;\nwhile (a < 3) {\n  a = a + 1;\n}\nif (a == 3) {\n  print a;\n} else {\n  print 0;\n}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = @import("parser.zig").Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try execute(arena.allocator(), statements.items);
}

test "interpreter handles block scope shadowing" {
    const source = "var a = 1; { var a = 2; print a; } print a;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = @import("parser.zig").Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try execute(arena.allocator(), statements.items);
}

test "interpreter handles functions and closures" {
    const source = "fun add(a, b) { return a + b; } print add(1, 2); fun makeAdder(a) { fun add(b) { return a + b; } return add; } var addTwo = makeAdder(2); print addTwo(3);";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = @import("parser.zig").Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try execute(arena.allocator(), statements.items);
}

test "interpreter handles logical operators" {
    const source = "print true or (1 / 0); print false and (1 / 0); print false or true; print true and false;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = @import("parser.zig").Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try execute(arena.allocator(), statements.items);
}

test "interpreter handles inheritance and super" {
    const source = "class A { speak() { print \"A\"; } } class B < A { speak() { super.speak(); print \"B\"; } } var b = B(); b.speak();";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try @import("scanner.zig").scanTokens(arena.allocator(), source);

    var parser = @import("parser.zig").Parser.init(arena.allocator(), tokens.items);
    const statements = try parser.parse();

    try execute(arena.allocator(), statements.items);
}

test "interpreter loads embedded stdlib modules" {
    const source = "import \"std/math.lox\"; print math.square(3); print math.answer;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try runSource(arena.allocator(), source);
}

test "interpreter clock builtin returns a number" {
    const source = "print clock() + 1;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try runSource(arena.allocator(), source);
}

test "interpreter file io builtins read and write files" {
    const io = std.testing.io_instance.io();
    const temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(io, .{ .sub_path = "data.txt", .data = "seed" });
    const data_path = try temp_dir.dir.realPathFileAlloc(io, "data.txt", std.testing.allocator);
    defer std.testing.allocator.free(data_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import "std/io.lox";
        \\io.writeFile("{s}", "hello from file io");
        \\print io.readFile("{s}");
    , .{ data_path, data_path });
    defer std.testing.allocator.free(source);

    try temp_dir.dir.writeFile(io, .{ .sub_path = "script.lox", .data = source });
    const source_path = try temp_dir.dir.realPathFileAlloc(io, "script.lox", std.testing.allocator);
    defer std.testing.allocator.free(source_path);

    try runFile(io, std.testing.allocator, source_path);
}
