const std = @import("std");

pub const ModuleSource = struct {
    path: []const u8,
    source: []const u8,
};

pub const modules = [_]ModuleSource{
    .{ .path = "std/math.lox", .source = @embedFile("../stdlib/math.lox") },
    .{ .path = "std/io.lox", .source = @embedFile("../stdlib/io.lox") },
};

pub fn getSource(path: []const u8) ?[]const u8 {
    inline for (modules) |module| {
        if (std.mem.eql(u8, path, module.path)) {
            return module.source;
        }
    }

    return null;
}
