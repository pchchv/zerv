const std = @import("std");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

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

        // expect allocator to be an Arena
        pub fn init(allocator: Allocator, opts: Opts) !*Self {
            const queue = try allocator.alloc(Args, opts.backlog);
            const threads = try allocator.alloc(Thread, opts.count);
            const thread_pool = try allocator.create(Self);

            thread_pool.* = .{
                .tail = 0,
                .head = 0,
                .mutex = .{},
                .stopped = false,
                .queue = queue,
                .read_cond = .{},
                .write_cond = .{},
                .threads = threads,
            };

            var started: usize = 0;
            errdefer {
                thread_pool.stopped = true;
                thread_pool.read_cond.broadcast();
                for (0..started) |i| {
                    threads[i].join();
                }
            }

            for (0..threads.len) |i| {
                const buffer = try allocator.alloc(u8, opts.buffer_size);
                threads[i] = try Thread.spawn(.{}, Self.worker, .{ thread_pool, buffer });
                started += 1;
            }

            return thread_pool;
        }

        pub fn stop(self: *Self) void {
            self.mutex.lock();
            self.stopped = true;
            self.mutex.unlock();

            self.read_cond.broadcast();
            for (self.threads) |thrd| {
                thrd.join();
            }
        }

        pub fn empty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.head == self.tail;
        }

        pub fn spawn(self: *Self, args: Args) void {
            const queue = self.queue;
            const queue_end = queue.len - 1;

            self.mutex.lock();
            while (self.isFull(queue_end)) {
                self.write_cond.wait(&self.mutex);
            }

            const head = self.head;
            queue[head] = args;
            self.head = if (head == queue_end) 0 else head + 1;
            self.mutex.unlock();

            self.read_cond.signal();
        }
    };
}
