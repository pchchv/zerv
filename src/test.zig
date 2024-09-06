// Internal helpers used by this library
const std = @import("std");

const Allocator = std.mem.Allocator;

const Conn = @import("worker.zig").HTTPConn;

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;
pub const allocator = std.testing.allocator;

pub var arena = std.heap.ArenaAllocator.init(allocator);

pub const Context = struct {
    fake: bool,
    conn: *Conn,
    to_read_pos: usize,
    closed: bool = false,
    stream: std.net.Stream, // the stream that the server gets
    client: std.net.Stream, // the client (e.g. browser stream)
    to_read: std.ArrayList(u8),
    arena: *std.heap.ArenaAllocator,
    _random: ?std.Random.DefaultPrng = null,
};

pub fn reset() void {
    _ = arena.reset(.free_all);
}

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub fn randomString(random: std.Random, a: Allocator, max: usize) []u8 {
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
