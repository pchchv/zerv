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

        pub fn add(self: *Self, key: K, value: V) void {
            const len = self.len;
            var keys = self.keys;
            if (len == keys.len) {
                return;
            }

            keys[len] = key;
            self.values[len] = value;
            self.len = len + 1;
        }

        pub fn get(self: *const Self, needle: K) ?V {
            const keys = self.keys[0..self.len];
            for (keys, 0..) |key, i| {
                if (equalFn(key, needle)) {
                    return self.values[i];
                }
            }
            return null;
        }
