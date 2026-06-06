const std = @import("std");

pub const Value = union(enum) {
    nil,
    bool: bool,
    number: f64,
    string: []const u8,
    function: *anyopaque,
    class: *anyopaque,
    instance: *anyopaque,
    module: *anyopaque,
};
