const std = @import("std");

const Allocator = std.mem.Allocator;

pub const KeyValue = MakeKeyValue([]const u8, []const u8, strEql);
pub const MultiFormKeyValue = MakeKeyValue([]const u8, MultiForm, strEql);

const MultiForm = struct {
    value: []const u8,
    filename: ?[]const u8 = null,
};

fn MakeKeyValue(K: type, V: type, equalFn: fn (lhs: K, rhs: K) bool) type {
    return struct {
        len: usize,
        keys: []K,
        values: []V,

        const Self = @This();

        pub const Value = V;
        pub const Iterator = struct {
            pos: usize,
            keys: [][]const u8,
            values: []V,

            const KV = struct {
                key: []const u8,
                value: V,
            };

            pub fn next(self: *Iterator) ?KV {
                const pos = self.pos;
                if (pos == self.keys.len) {
                    return null;
                }

                self.pos = pos + 1;
                return .{
                    .key = self.keys[pos],
                    .value = self.values[pos],
                };
            }
        };

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

        pub fn reset(self: *Self) void {
            self.len = 0;
        }

        pub fn iterator(self: *const Self) Iterator {
            const len = self.len;
            return .{
                .pos = 0,
                .keys = self.keys[0..len],
                .values = self.values[0..len],
            };
        }
    };
}

fn strEql(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, lhs, rhs);
}
