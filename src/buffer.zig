const std = @import("std");

const blockingMode = @import("httpz.zig").blockingMode;

const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

pub const Buffer = struct {
    data: []u8,
    type: Type,

    const Type = enum {
        arena,
        static,
        pooled,
        dynamic,
    };
};

/// Pool is shared by threads in the blocking worker's thread pool when we are in blocking mode.
/// Thus, needed to synchronize accesses.
/// When we are not in locking mode,
/// each worker gets its own Pool,
/// and the pool is accessed only from that worker thread,
///  so no locking is required.
pub const Pool = struct {
    const M = if (blockingMode()) Mutex else void;

    available: usize,
    buffers: []Buffer,
    allocator: Allocator,
    buffer_size: usize,
    mutex: M,
};
