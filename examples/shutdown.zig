// This example demonstrates how to shutdown zerv.
// Only works on Linux/MacOS/BSD.

const std = @import("std");
const zerv = @import("zerv");

fn index(_: *zerv.Request, res: *zerv.Response) !void {
    const writer = res.writer();
    return std.fmt.format(writer, "To shutdown, run:\nkill -s int {d}", .{std.c.getpid()});
}
