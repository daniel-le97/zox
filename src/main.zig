const std = @import("std");
const zox = @import("zox");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 2) {
        std.debug.print("Usage: zox [script]\n", .{});
        std.process.exit(64);
    }

    if (args.len == 2) {
        try zox.runFile(init.io, arena, args[1]);
        return;
    }

    std.debug.print("zox: pass a .lox file, e.g. `zig build run -- examples/hello.lox`\n", .{});
}
