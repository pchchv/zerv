const std = @import("std");

const zerv = @import("zerv.zig");
const buffer = @import("buffer.zig");
// const metrics = @import("metrics.zig");

const Self = @This();

const Url = @import("url.zig").Url;
const Params = @import("params.zig").Params;
const HTTPConn = @import("worker.zig").HTTPConn;
const KeyValue = @import("key_value.zig").KeyValue;
const MultiFormKeyValue = @import("key_value.zig").MultiFormKeyValue;
// const Config = @import("config.zig").Config.Request;

// const os = std.os;
// const Stream = std.net.Stream;
const Address = std.net.Address;
const Allocator = std.mem.Allocator;
// const ArenaAllocator = std.heap.ArenaAllocator;

pub const Request = struct {
    // The URL of the request
    url: Url,

    // the address of the client
    address: Address,

    // Path params (extracted from the URL based on the route).
    // Using req.param(NAME) is preferred.
    params: Params,

    // The headers of the request. Using req.header(NAME) is preferred.
    headers: KeyValue,

    // The request method.
    method: zerv.Method,

    // The request protocol.
    protocol: zerv.Protocol,

    // The body of the request, if any.
    body_buffer: ?buffer.Buffer = null,
    body_len: usize = 0,

    // cannot use an optional on qs, because it's pre-allocated so always exists
    qs_read: bool = false,

    // The query string lookup.
    qs: KeyValue,

    // cannot use an optional on fd, because it's pre-allocated so always exists
    fd_read: bool = false,

    // The formData lookup.
    fd: KeyValue,

    // The multiFormData lookup.
    mfd: MultiFormKeyValue,

    // Spare space we still have in our static buffer after parsing the request
    // We can use this, if needed, for example to unescape querystring parameters
    spare: []u8,

    // An arena that will be reset at the end of each request. Can be used
    // internally by this framework. The application is also free to make use of
    // this arena. This is the same arena as response.arena.
    arena: Allocator,

    route_data: ?*const anyopaque,

    // Arbitrary place for middlewares (or really anyone), to store data.
    // Middleware can store data here while executing, and then provide a function
    // to retrieved the [typed] data to the action.
    middlewares: *std.StringHashMap(*anyopaque),

    pub const State = Self.State;
    pub const Config = Self.Config;
    pub const Reader = Self.Reader;

    const MultiPartField = struct {
        name: []const u8,
        value: MultiFormKeyValue.Value,
    };

    const ContentDispositionAttributes = struct {
        name: []const u8,
        filename: ?[]const u8 = null,
    };

    pub fn init(arena: Allocator, conn: *HTTPConn) Request {
        const state = &conn.req_state;
        return .{
            .arena = arena,
            .qs = state.qs,
            .fd = state.fd,
            .mfd = state.mfd,
            .method = state.method.?,
            .protocol = state.protocol.?,
            .url = Url.parse(state.url.?),
            .address = conn.address,
            .route_data = null,
            .params = state.params,
            .headers = state.headers,
            .body_buffer = state.body,
            .body_len = state.body_len,
            .spare = state.buf[state.pos..],
            .middlewares = &state.middlewares,
        };
    }

    pub fn body(self: *const Request) ?[]const u8 {
        const buf = self.body_buffer orelse return null;
        return buf.data[0..self.body_len];
    }

    /// `name` should be full lowercase
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn query(self: *Request) !KeyValue {
        if (self.qs_read) {
            return self.qs;
        }
        return self.parseQuery();
    }

    pub fn json(self: *Request, comptime T: type) !?T {
        const b = self.body() orelse return null;
        return try std.json.parseFromSliceLeaky(T, self.arena, b, .{});
    }

    pub fn jsonValue(self: *Request) !?std.json.Value {
        const b = self.body() orelse return null;
        return try std.json.parseFromSliceLeaky(std.json.Value, self.arena, b, .{});
    }

    pub fn jsonObject(self: *Request) !?std.json.ObjectMap {
        const value = try self.jsonValue() orelse return null;
        switch (value) {
            .object => |o| return o,
            else => return null,
        }
    }

    pub fn canKeepAlive(self: *const Request) bool {
        return switch (self.protocol) {
            zerv.Protocol.HTTP11 => {
                if (self.headers.get("connection")) |conn| {
                    return !std.mem.eql(u8, conn, "close");
                }
                return true;
            },
            zerv.Protocol.HTTP10 => return false, // TODO: support this in the cases where it can be
        };
    }

    pub fn formData(self: *Request) !KeyValue {
        if (self.fd_read) {
            return self.fd;
        }
        return self.parseFormData();
    }

    pub fn multiFormData(self: *Request) !MultiFormKeyValue {
        if (self.fd_read) {
            return self.mfd;
        }
        return self.parseMultiFormData();
    }

    // Is needed to allocate memory to parse the querystring.
    // Specifically, if there's a url-escaped component (a key or value),
    // is needed memory to store the un-escaped version.
    fn parseQuery(self: *Request) !KeyValue {
        const raw = self.url.query;
        if (raw.len == 0) {
            self.qs_read = true;
            return self.qs;
        }

        var qs = &self.qs;
        var buf = self.spare;
        const allocator = self.arena;

        var it = std.mem.splitScalar(u8, raw, '&');
        while (it.next()) |pair| {
            if (std.mem.indexOfScalarPos(u8, pair, 0, '=')) |sep| {
                const key_res = try Url.unescape(allocator, buf, pair[0..sep]);
                if (key_res.buffered) {
                    buf = buf[key_res.value.len..];
                }

                const value_res = try Url.unescape(allocator, buf, pair[sep + 1 ..]);
                if (value_res.buffered) {
                    buf = buf[value_res.value.len..];
                }

                qs.add(key_res.value, value_res.value);
            } else {
                const key_res = try Url.unescape(allocator, buf, pair);
                if (key_res.buffered) {
                    buf = buf[key_res.value.len..];
                }
                qs.add(key_res.value, "");
            }
        }

        self.spare = buf;
        self.qs_read = true;
        return self.qs;
    }
};
