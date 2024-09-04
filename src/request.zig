const std = @import("std");

const zerv = @import("zerv.zig");
const buffer = @import("buffer.zig");

const Self = @This();

const Url = @import("url.zig").Url;
const Params = @import("params.zig").Params;
const HTTPConn = @import("worker.zig").HTTPConn;
const KeyValue = @import("key_value.zig").KeyValue;
const MultiFormKeyValue = @import("key_value.zig").MultiFormKeyValue;
const Config = @import("config.zig").Config.Request;

const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

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

    fn getContentDispotionAttributes(fields: []u8) !ContentDispositionAttributes {
        var pos: usize = 0;
        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        while (pos < fields.len) {
            {
                const b = fields[pos];
                if (b == ';' or b == ' ' or b == '\t') {
                    pos += 1;
                    continue;
                }
            }

            const sep = std.mem.indexOfScalarPos(u8, fields, pos, '=') orelse return error.InvalidMultiPartEncoding;
            const field_name = fields[pos..sep];

            // skip the equal
            const value_start = sep + 1;
            if (value_start == fields.len) {
                return error.InvalidMultiPartEncoding;
            }

            var value: []const u8 = undefined;
            if (fields[value_start] != '"') {
                const value_end = std.mem.indexOfScalarPos(u8, fields, pos, ';') orelse fields.len;
                pos = value_end;
                value = fields[value_start..value_end];
            } else blk: {
                // skip the double quote
                pos = value_start + 1;
                var write_pos = pos;
                while (pos < fields.len) {
                    switch (fields[pos]) {
                        '\\' => {
                            if (pos == fields.len) {
                                return error.InvalidMultiPartEncoding;
                            }
                            // supposedly MSIE doesn't always escape \,
                            // so if the \ isn't escape one of the special characters,
                            // it must be a single \.
                            switch (fields[pos + 1]) {
                                '(', ')', '<', '>', '@', ',', ';', ':', '"', '/', '[', ']', '?', '=' => |n| {
                                    fields[write_pos] = n;
                                    pos += 1;
                                },
                                else => fields[write_pos] = '\\',
                            }
                        },
                        '"' => {
                            pos += 1;
                            value = fields[value_start + 1 .. write_pos];
                            break :blk;
                        },
                        else => |b| fields[write_pos] = b,
                    }
                    pos += 1;
                    write_pos += 1;
                }
                return error.InvalidMultiPartEncoding;
            }

            if (std.mem.eql(u8, field_name, "name")) {
                name = value;
            } else if (std.mem.eql(u8, field_name, "filename")) {
                filename = value;
            }
        }

        return .{
            .name = name orelse return error.InvalidMultiPartEncoding,
            .filename = filename,
        };
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

    fn parseFormData(self: *Request) !KeyValue {
        const b = self.body() orelse "";
        if (b.len == 0) {
            self.fd_read = true;
            return self.fd;
        }

        const allocator = self.arena;
        var fd = &self.fd;
        var buf = self.spare;
        var it = std.mem.splitScalar(u8, b, '&');
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
                fd.add(key_res.value, value_res.value);
            } else {
                const key_res = try Url.unescape(allocator, buf, pair);
                if (key_res.buffered) {
                    buf = buf[key_res.value.len..];
                }
                fd.add(key_res.value, "");
            }
        }

        self.spare = buf;
        self.fd_read = true;
        return self.fd;
    }

    fn parseMultiPartEntry(entry: []const u8) !MultiPartField {
        var pos: usize = 0;
        var attributes: ?ContentDispositionAttributes = null;
        while (true) {
            const end_line_pos = std.mem.indexOfScalarPos(u8, entry, pos, '\n') orelse return error.InvalidMultiPartEncoding;
            const line = entry[pos..end_line_pos];

            pos = end_line_pos + 1;
            if (line.len == 0 or line[line.len - 1] != '\r') return error.InvalidMultiPartEncoding;

            if (line.len == 1) {
                break;
            }

            // is needed to look for the name
            if (std.ascii.startsWithIgnoreCase(line, "content-disposition:") == false) {
                continue;
            }

            const value = trimLeadingSpace(line["content-disposition:".len..]);
            if (std.ascii.startsWithIgnoreCase(value, "form-data;") == false) {
                return error.InvalidMultiPartEncoding;
            }

            // constCast is safe here because this ultilately comes from one of buffers
            const value_start = "form-data;".len;
            const value_end = value.len - 1; // remove the trailing \r
            attributes = try getContentDispotionAttributes(@constCast(trimLeadingSpace(value[value_start..value_end])));
        }

        const value = entry[pos..];
        if (value.len < 2 or value[value.len - 2] != '\r' or value[value.len - 1] != '\n') {
            return error.InvalidMultiPartEncoding;
        }

        const attr = attributes orelse return error.InvalidMultiPartEncoding;

        return .{
            .name = attr.name,
            .value = .{
                .value = value[0 .. value.len - 2],
                .filename = attr.filename,
            },
        };
    }

    fn parseMultiFormData(self: *Request) !MultiFormKeyValue {
        const body_ = self.body() orelse "";
        if (body_.len == 0) {
            self.fd_read = true;
            return self.mfd;
        }

        const content_type = blk: {
            if (self.header("content-type")) |content_type| {
                if (std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) {
                    break :blk content_type;
                }
            }
            return error.NotMultipartForm;
        };

        // Max boundary length is 70.
        // Plus the two leading dashes (--)
        var boundary_buf: [72]u8 = undefined;
        const boundary = blk: {
            const directive = content_type["multipart/form-data".len..];
            for (directive, 0..) |b, i| loop: {
                if (b != ' ' and b != ';') {
                    if (std.ascii.startsWithIgnoreCase(directive[i..], "boundary=")) {
                        const raw_boundary = directive["boundary=".len + i ..];
                        if (raw_boundary.len > 0 and raw_boundary.len <= 70) {
                            boundary_buf[0] = '-';
                            boundary_buf[1] = '-';
                            if (raw_boundary[0] == '"') {
                                if (raw_boundary.len > 2 and raw_boundary[raw_boundary.len - 1] == '"') {
                                    // it's really -2, since we need to strip out the two quotes
                                    // but buf is already at + 2, so they cancel out.
                                    const end = raw_boundary.len;
                                    @memcpy(boundary_buf[2..end], raw_boundary[1 .. raw_boundary.len - 1]);
                                    break :blk boundary_buf[0..end];
                                }
                            } else {
                                const end = 2 + raw_boundary.len;
                                @memcpy(boundary_buf[2..end], raw_boundary);
                                break :blk boundary_buf[0..end];
                            }
                        }
                    }
                    // not valid, break out of the loop
                    // can return an error.InvalidMultiPartFormDataHeader
                    break :loop;
                }
            }
            return error.InvalidMultiPartFormDataHeader;
        };

        var mfd = &self.mfd;
        var entry_it = std.mem.splitSequence(u8, body_, boundary);
        {
            // expect the body to begin with a boundary
            const first = entry_it.next() orelse {
                self.fd_read = true;
                return self.mfd;
            };
            if (first.len != 0) {
                return error.InvalidMultiPartEncoding;
            }
        }

        while (entry_it.next()) |entry| {
            // body ends with -- after a final boundary
            if (entry.len == 4 and entry[0] == '-' and entry[1] == '-' and entry[2] == '\r' and entry[3] == '\n') {
                break;
            }

            if (entry.len < 2 or entry[0] != '\r' or entry[1] != '\n') return error.InvalidMultiPartEncoding;

            // [2..] to skip boundary's trailing line terminator
            const field = try parseMultiPartEntry(entry[2..]);
            mfd.add(field.name, field.value);
        }

        self.fd_read = true;
        return self.mfd;
    }
};

// All зщыышиду the upfront memory allocation.
// Each worker keeps a pool of these to reuse.
pub const State = struct {
    // Header must fit in here.
    // Extra space can be used to fit the body or decode URL parameters.
    buf: []u8,

    // position in buf that we've parsed up to
    pos: usize,

    // length of buffer for which we have valid data
    len: usize,

    // Lazy-loaded in request.query();
    qs: KeyValue,

    // Lazy-loaded in request.formData();
    fd: KeyValue,

    // Lazy-loaded in request.multiFormData();
    mfd: MultiFormKeyValue,

    // Populated after we've parsed the request,
    // once matching the request to a route.
    params: Params,

    // constant config, but it's the only field needed,
    max_body_size: usize,

    // For reading the body, might needed more than `buf`.
    buffer_pool: *buffer.Pool,

    url: ?[]u8,

    method: ?zerv.Method,

    protocol: ?zerv.Protocol,

    // The headers, might be partially parsed.
    // From the outside, there's no way to know if this is fully parsed or not.
    // There doesn't have to be.
    // This is because once finish parsing the headers,
    // if there's no body,
    // signal the worker that have a complete request and it can proceed to handle it.
    // Thus, body == null or body_len == 0 doesn't mean anything.
    headers: KeyValue,

    // This be a slice pointing to` buf`,
    // or be from the buffer_pool or be dynamically allocated.
    body: ?buffer.Buffer,

    // position in body.data that have valid data for
    body_pos: usize,

    // the full length of the body, might not have that much data yet
    body_len: usize,

    arena: *ArenaAllocator,

    middlewares: std.StringHashMap(*anyopaque),

    pub fn init(allocator: Allocator, arena: *ArenaAllocator, buffer_pool: *buffer.Pool, config: *const Config) !Request.State {
        return .{
            .pos = 0,
            .len = 0,
            .url = null,
            .method = null,
            .protocol = null,
            .body = null,
            .body_pos = 0,
            .body_len = 0,
            .arena = arena,
            .buffer_pool = buffer_pool,
            .max_body_size = config.max_body_size orelse 1_048_576,
            .middlewares = std.StringHashMap(*anyopaque).init(allocator),
            .qs = try KeyValue.init(allocator, config.max_query_count orelse 32),
            .fd = try KeyValue.init(allocator, config.max_form_count orelse 0),
            .mfd = try MultiFormKeyValue.init(allocator, config.max_multiform_count orelse 0),
            .buf = try allocator.alloc(u8, config.buffer_size orelse 4_096),
            .headers = try KeyValue.init(allocator, config.max_header_count orelse 32),
            .params = try Params.init(allocator, config.max_param_count orelse 10),
        };
    }
};

inline fn trimLeadingSpaceCount(in: []const u8) struct { []const u8, usize } {
    if (in.len > 1 and in[0] == ' ') {
        const n = in[1];
        if (n != ' ' and n != '\t') {
            return .{ in[1..], 1 };
        }
    }

    for (in, 0..) |b, i| {
        if (b != ' ' and b != '\t') return .{ in[i..], i };
    }
    return .{ "", in.len };
}

inline fn trimLeadingSpace(in: []const u8) []const u8 {
    const out, _ = trimLeadingSpaceCount(in);
    return out;
}
