const std = @import("std");

const Allocator = std.mem.Allocator;

fn MakeKeyValue(K: type, V: type, equalFn: fn (lhs: K, rhs: K) bool) type {
    return struct {
        len: usize,
        keys: []K,
        values: []V,
        const Self = @This();

        pub fn init(allocator: Allocator, max: usize) !Self {
            return .{
                .len = 0,
                .keys = try allocator.alloc(K, max),
                .values = try allocator.alloc(V, max),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.keys);
            allocator.free(self.values);
        }
    };
}
