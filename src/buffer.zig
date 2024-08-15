const std = @import("std");
const metrics = @import("metrics.zig");

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

    pub fn init(allocator: Allocator, count: usize, buffer_size: usize) !Pool {
        const buffers = try allocator.alloc(Buffer, count);
        errdefer allocator.free(buffers);

        var initialized: usize = 0;
        errdefer {
            for (0..initialized) |i| {
                allocator.free(buffers[i].data);
            }
        }

        for (0..count) |i| {
            buffers[i] = .{
                .type = .pooled,
                .data = try allocator.alloc(u8, buffer_size),
            };
            initialized += 1;
        }

        return .{
            .mutex = if (comptime blockingMode()) .{} else {},
            .buffers = buffers,
            .available = count,
            .allocator = allocator,
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *Pool) void {
        const allocator = self.allocator;
        for (self.buffers) |buf| {
            allocator.free(buf.data);
        }
        allocator.free(self.buffers);
    }

    pub fn grow(self: *Pool, arena: Allocator, buffer: *Buffer, current_size: usize, new_size: usize) !Buffer {
        if (buffer.type == .dynamic and arena.resize(buffer.data, new_size)) {
            buffer.data = buffer.data.ptr[0..new_size];
            return buffer.*;
        }

        const new_buffer = try self.arenaAlloc(arena, new_size);
        @memcpy(new_buffer.data[0..current_size], buffer.data[0..current_size]);
        self.release(buffer.*);
        return new_buffer;
    }

    pub fn static(self: Pool, size: usize) !Buffer {
        return .{
            .type = .static,
            .data = try self.allocator.alloc(u8, size),
        };
    }

    pub fn alloc(self: *Pool, size: usize) !Buffer {
        return self.allocType(self.allocator, .dynamic, size);
    }

    pub fn arenaAlloc(self: *Pool, arena: Allocator, size: usize) !Buffer {
        return self.allocType(arena, .arena, size);
    }

    fn allocType(self: *Pool, allocator: Allocator, buffer_type: Buffer.Type, size: usize) !Buffer {
        if (size > self.buffer_size) {
            metrics.allocBufferLarge(size);
            return .{
                .type = buffer_type,
                .data = try allocator.alloc(u8, size),
            };
        }

        self.lock();
        const available = self.available;
        if (available == 0) {
            self.unlock();
            metrics.allocBufferEmpty(size);
            return .{
                .type = buffer_type,
                .data = try allocator.alloc(u8, size),
            };
        }
        defer self.unlock();

        const index = available - 1;
        const buffer = self.buffers[index];
        self.available = index;
        return buffer;
    }

    pub fn free(self: *Pool, buffer: Buffer) void {
        switch (buffer.type) {
            .arena => {},
            .pooled => self.release(buffer),
            .static => self.allocator.free(buffer.data),
            .dynamic => self.allocator.free(buffer.data),
        }
    }

    pub fn release(self: *Pool, buffer: Buffer) void {
        switch (buffer.type) {
            .static, .arena => {},
            .dynamic => self.allocator.free(buffer.data),
            .pooled => {
                self.lock();
                defer self.unlock();
                const available = self.available;
                self.buffers[available] = buffer;
                self.available = available + 1;
            },
        }
    }

    inline fn lock(self: *Pool) void {
        if (comptime blockingMode()) {
            self.mutex.lock();
        }
    }

    inline fn unlock(self: *Pool) void {
        if (comptime blockingMode()) {
            self.mutex.unlock();
        }
    }
};
