const zerv = @import("zerv.zig");
const request = @import("request.zig");
const response = @import("response.zig");

const DEFAULT_WORKERS = 2;

pub const Config = struct {
    port: ?u16 = null,
    address: ?[]const u8 = null,
    unix_path: ?[]const u8 = null,
    workers: Worker = .{},
    request: Request = .{},
    response: Response = .{},
    timeout: Timeout = .{},
    thread_pool: ThreadPool = .{},
    websocket: Websocket = .{},

    pub const Worker = struct {
        count: ?u16 = null,
        max_conn: ?u16 = null,
        min_conn: ?u16 = null,
        large_buffer_count: ?u16 = null,
        large_buffer_size: ?u32 = null,
        retain_allocated_bytes: ?usize = null,
    };

    pub const Request = struct {
        max_body_size: ?usize = null,
        buffer_size: ?usize = null,
        max_header_count: ?usize = null,
        max_param_count: ?usize = null,
        max_query_count: ?usize = null,
        max_form_count: ?usize = null,
        max_multiform_count: ?usize = null,
    };

    pub const Response = struct {
        max_header_count: ?usize = null,
    };

    pub const Timeout = struct {
        request: ?u32 = null,
        keepalive: ?u32 = null,
        request_count: ?u32 = null,
    };

    pub const ThreadPool = struct {
        count: ?u16 = null,
        backlog: ?u32 = null,
        buffer_size: ?usize = null,
    };

    pub const Websocket = struct {
        max_message_size: ?usize = null,
        small_buffer_size: ?usize = null,
        small_buffer_pool: ?usize = null,
        large_buffer_size: ?usize = null,
        large_buffer_pool: ?u16 = null,
    };

    pub fn threadPoolCount(self: *const Config) u32 {
        const thread_count = self.thread_pool.count orelse 4;

        // In blockingMode there is only 1 worker (regardless of configuration).
        // It is necessary that blocking and non-blocking modes use the same number of threads,
        // so convert the extra workers into thread pool threads.
        // In blockingMode, the worker does relatively little work,
        // while thread pool threads do more,
        // so this rebalancing makes some sense,
        // and can always be abandoned by explicitly setting config.workers.count = 1
        if (zerv.blockingMode()) {
            const worker_count = self.workerCount();
            if (worker_count > 1) {
                return thread_count + worker_count - 1;
            }
        }
        return thread_count;
    }

    pub fn workerCount(self: *const Config) u32 {
        if (zerv.blockingMode()) {
            return 1;
        }
        return self.workers.count orelse DEFAULT_WORKERS;
    }
};
