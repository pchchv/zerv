// This example demonstrates how to shutdown zerv.
// Only works on Linux/MacOS/BSD.

const std = @import("std");
const zerv = @import("zerv");

const PORT = 8809;

var server_instance: ?*zerv.Server(void) = null;

pub fn main() !void {
    if (comptime @import("builtin").os.tag == .windows) {
        std.debug.print("This example does not run on Windows. Sorry\n", .{});
        return error.PlatformNotSupported;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // call shutdown function (below)
    // when SIGINT or SIGTERM are received
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    var server = try zerv.Server(void).init(allocator, .{ .port = PORT }, {});
    defer server.deinit();

    var router = server.router(.{});
    router.get("/", index, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});
    std.debug.print("process id (pid): {d}\n", .{std.c.getpid()});

    server_instance = &server;
    try server.listen();
}

fn index(_: *zerv.Request, res: *zerv.Response) !void {
    const writer = res.writer();
    return std.fmt.format(writer, "To shutdown, run:\nkill -s int {d}", .{std.c.getpid()});
}

fn shutdown(_: c_int) callconv(.C) void {
    if (server_instance) |server| {
        server_instance = null;
        server.stop();
    }
}
