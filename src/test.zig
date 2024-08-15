// Internal helpers used by this library
const std = @import("std");

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;
pub const allocator = std.testing.allocator;

pub var arena = std.heap.ArenaAllocator.init(allocator);

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub fn reset() void {
    _ = arena.reset(.free_all);
}

pub fn randomString(random: std.Random, a: std.mem.Allocator, max: usize) []u8 {
    var buf = a.alloc(u8, random.uintAtMost(usize, max) + 1) catch unreachable;
    const valid = "abcdefghijklmnopqrstuvwxyz0123456789-_";
    for (0..buf.len) |i| {
        buf[i] = valid[random.uintAtMost(usize, valid.len - 1)];
    }
    return buf;
}

pub fn getRandom() std.Random.DefaultPrng {
    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    return std.Random.DefaultPrng.init(seed);
}
