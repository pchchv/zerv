const std = @import("std");
const zerv = @import("../zerv.zig");

pub const Config = struct {
    origin: []const u8,
    headers: ?[]const u8 = null,
    methods: ?[]const u8 = null,
    max_age: ?[]const u8 = null,
};

origin: []const u8,
headers: ?[]const u8 = null,
methods: ?[]const u8 = null,
max_age: ?[]const u8 = null,

const Cors = @This();
