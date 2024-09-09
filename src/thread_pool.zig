const std = @import("std");

const Thread = std.Thread;

pub const Opts = struct {
    count: u32,
    backlog: u32,
    buffer_size: usize,
};

pub fn ThreadPool(comptime F: anytype) type {
    // When the worker thread calls F, it'll inject its static buffer.
    // So F would be: handle(server: *Server, conn: *Conn, buf: []u8)
    // and FullArgs would be 3 args....
    const FullArgs = std.meta.ArgsTuple(@TypeOf(F));
    const full_fields = std.meta.fields(FullArgs);
    const ARG_COUNT = full_fields.len - 1;

    // Args will be FullArgs[0..len-1],
    // so in the above example args will be\
    // (*Server, *Conn)
    // Args is what is expected to be passed to the caller in spawn.
    // The worker thread will convert Args to FullArgs by adding its static buffer as the last argument.

    var fields: [ARG_COUNT]std.builtin.Type.StructField = undefined;
    inline for (full_fields[0..ARG_COUNT], 0..) |field, index| fields[index] = field;

    const Args = comptime @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .fields = &fields,
            .decls = &.{},
        },
    });

    return struct {
        // position in queue to read from
        tail: usize,

        // position in the queue to write to
        head: usize,

        // pendind jobs
        queue: []Args,

        stopped: bool,
        threads: []Thread,
        mutex: Thread.Mutex,
        read_cond: Thread.Condition,
        write_cond: Thread.Condition,

        const Self = @This();
    };
}
