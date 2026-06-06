const std = @import("std");
const ast = @import("ast.zig");

pub const RuntimeError = error{ InvalidOperand, DivisionByZero, OutOfMemory, UndefinedVariable, NotCallable, WrongArity, InvalidReturn, ReturnSignal, BreakSignal, ContinueSignal, InvalidBreak, InvalidContinue, ImportUnavailable, ImportFailed, ImportCycle };

pub const BuiltinContext = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
};

pub const BuiltinCallback = *const fn (BuiltinContext, []const ast.LiteralValue) RuntimeError!ast.LiteralValue;

pub const BuiltinFunction = struct {
    name: []const u8,
    arity: ?usize,
    callback: BuiltinCallback,
};
