const std = @import("std");

var testSum: u64 = 0;

fn testIncr(c: u64, buf: []u8) void {
    std.debug.assert(buf.len == 512);
    _ = @atomicRmw(u64, &testSum, .Add, c, .monotonic);
    // let the threadpool queue get backed up
    std.time.sleep(std.time.ns_per_us * 100);
}
