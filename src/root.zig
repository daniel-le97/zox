const std = @import("std");
pub const ast = @import("ast.zig");
pub const interpreter = @import("interpreter.zig");
pub const parser = @import("parser.zig");
pub const scanner = @import("scanner.zig");
pub const token = @import("token.zig");

pub fn runSource(allocator: std.mem.Allocator, source: []const u8) !void {
    try interpreter.runSource(allocator, source);
}

pub fn runSourceAtPath(allocator: std.mem.Allocator, source: []const u8, source_path: []const u8) !void {
    try interpreter.runSourceWithPath(allocator, source, source_path, null);
}

pub fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    try interpreter.runFile(io, allocator, path);
}

test "scanner reads basic expression" {
    const input = "print 1 + 2;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try scanner.scanTokens(arena.allocator(), input);

    try std.testing.expect(tokens.items.len >= 5);
    try std.testing.expectEqual(token.TokenType.print_kw, tokens.items[0].typ);
}
