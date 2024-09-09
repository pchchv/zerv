const std = @import("std");

const t = @import("test.zig");
const thp = @import("thread_pool.zig");

var testSum: u64 = 0;

test "ThreadPool: small fuzz" {
    defer t.reset();

    testSum = 0; // global defined near the end of this file
    var tp = try thp.ThreadPool(testIncr).init(t.arena.allocator(), .{ .count = 3, .backlog = 3, .buffer_size = 512 });

    for (0..50_000) |_| {
        tp.spawn(.{1});
    }

    while (tp.empty() == false) {
        std.time.sleep(std.time.ns_per_ms);
    }

    tp.stop();
    try t.expectEqual(50_000, testSum);
}

test "ThreadPool: large fuzz" {
    defer t.reset();

    testSum = 0; // global defined near the end of this file
    var tp = try thp.ThreadPool(testIncr).init(t.arena.allocator(), .{ .count = 50, .backlog = 1000, .buffer_size = 512 });

    for (0..50_000) |_| {
        tp.spawn(.{1});
    }
    while (tp.empty() == false) {
        std.time.sleep(std.time.ns_per_ms);
    }
    tp.stop();
    try t.expectEqual(50_000, testSum);
}

fn testIncr(c: u64, buf: []u8) void {
    std.debug.assert(buf.len == 512);
    _ = @atomicRmw(u64, &testSum, .Add, c, .monotonic);
    // let the threadpool queue get backed up
    std.time.sleep(std.time.ns_per_us * 100);
}
