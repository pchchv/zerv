const request = @import("request.zig");
const response = @import("response.zig");

pub const Config = struct {
    port: ?u16 = null,
    address: ?[]const u8 = null,
    unix_path: ?[]const u8 = null,
    workers: Worker = .{},
    request: Request = .{},
    response: Response = .{},
    timeout: Timeout = .{},
    cors: ?CORS = null,
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
};
