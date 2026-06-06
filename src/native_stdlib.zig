const std = @import("std");
const ast = @import("ast.zig");
const runtime = @import("runtime.zig");

const Builtin = runtime.BuiltinFunction;

pub fn install(host: anytype) !void {
    inline for (builtins) |builtin| {
        try host.defineBuiltin(builtin.name, builtin.arity, builtin.callback);
    }
}

const builtins = [_]Builtin{
    .{ .name = "clock", .arity = 0, .callback = builtinClock },
    .{ .name = "read_file", .arity = 1, .callback = builtinReadFile },
    .{ .name = "write_file", .arity = 2, .callback = builtinWriteFile },
};

fn builtinClock(context: runtime.BuiltinContext, arguments: []const ast.LiteralValue) runtime.RuntimeError!ast.LiteralValue {
    _ = context;
    if (arguments.len != 0) return error.WrongArity;
    return .{ .number = @as(f64, @floatFromInt(std.time.timestamp())) };
}

fn builtinReadFile(context: runtime.BuiltinContext, arguments: []const ast.LiteralValue) runtime.RuntimeError!ast.LiteralValue {
    if (arguments.len != 1) return error.WrongArity;
    const path = switch (arguments[0]) {
        .string => |value| value,
        else => return error.InvalidOperand,
    };

    const io = context.io orelse return error.ImportUnavailable;
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch return error.ImportFailed;
    const buffer = try context.allocator.alloc(u8, @intCast(stat.size));
    const read = cwd.readFile(io, path, buffer) catch {
        context.allocator.free(buffer);
        return error.ImportFailed;
    };

    if (read.len != buffer.len) {
        const result = try context.allocator.dupe(u8, read);
        context.allocator.free(buffer);
        return .{ .string = result };
    }

    return .{ .string = buffer };
}

fn builtinWriteFile(context: runtime.BuiltinContext, arguments: []const ast.LiteralValue) runtime.RuntimeError!ast.LiteralValue {
    if (arguments.len != 2) return error.WrongArity;
    const path = switch (arguments[0]) {
        .string => |value| value,
        else => return error.InvalidOperand,
    };
    const contents = switch (arguments[1]) {
        .string => |value| value,
        else => return error.InvalidOperand,
    };

    const io = context.io orelse return error.ImportUnavailable;
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = path, .data = contents }) catch return error.ImportFailed;
    return .nil;
}
