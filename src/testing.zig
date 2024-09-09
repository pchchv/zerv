// Helpers for application developers to be able to mock request and parse responses.

const std = @import("std");

const t = @import("test.zig");
const zerv = @import("zerv.zig");

const Conn = @import("worker.zig").HTTPConn;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const Testing = struct {
    _ctx: t.Context,
    conn: *Conn,
    req: *zerv.Request,
    res: *zerv.Response,
    arena: std.mem.Allocator,
    parsed_response: ?Response = null,

    pub const Response = struct {
        status: u16,
        raw: []const u8,
        body: []const u8,
        allocator: std.mem.Allocator,
        headers: std.StringHashMap([]const u8),

        pub fn expectHeader(self: Response, name: []const u8, expected: ?[]const u8) !void {
            if (expected) |e| {
                try t.expectString(e, self.headers.get(name).?);
            } else {
                try t.expectEqual(null, self.headers.get(name));
            }
        }

        pub fn expectJson(self: Response, expected: anytype) !void {
            if (self.headers.get("Content-Type")) |ct| {
                try t.expectString("application/json", ct);
            } else {
                return error.NoContentTypeHeader;
            }

            var jc = JsonComparer.init(t.allocator);
            defer jc.deinit();
            const diffs = try jc.compare(expected, self.body);
            if (diffs.items.len == 0) {
                return;
            }

            for (diffs.items, 0..) |diff, i| {
                std.debug.print("\n==Difference #{d}==\n", .{i + 1});
                std.debug.print("  {s}: {s}\n  Left: {s}\n  Right: {s}\n", .{ diff.path, diff.err, diff.a, diff.b });
                std.debug.print("  Actual:\n    {s}\n", .{self.body});
            }
            return error.JsonNotEqual;
        }

        pub fn deinit(self: *Response) void {
            self.headers.deinit();
            self.allocator.free(self.raw);
        }
    };

    pub fn deinit(self: *Testing) void {
        self._ctx.deinit();
    }

    pub fn query(self: *Testing, name: []const u8, value: []const u8) void {
        const req = self.req;
        req.qs_read = true;
        req.qs.add(name, value);

        const encoded_name = escapeString(self.arena, name) catch unreachable;
        const encoded_value = escapeString(self.arena, value) catch unreachable;
        const kv = std.fmt.allocPrint(self.arena, "{s}={s}", .{ encoded_name, encoded_value }) catch unreachable;

        const q = req.url.query;
        if (q.len == 0) {
            req.url.query = kv;
        } else {
            req.url.query = std.fmt.allocPrint(self.arena, "{s}&{s}", .{ q, kv }) catch unreachable;
        }
    }

    pub fn url(self: *Testing, u: []const u8) void {
        self.req.url = zerv.Url.parse(u);
    }

    pub fn json(self: *Testing, value: anytype) void {
        var arr = ArrayList(u8).init(self.arena);
        std.json.stringify(value, .{}, arr.writer()) catch unreachable;
        self.req.body_buffer = .{ .type = .static, .data = arr.items };
        self.req.body_len = arr.items.len;
    }

    pub fn param(self: *Testing, name: []const u8, value: []const u8) void {
        // This is ugly, but the Param structure is optimized for how the router
        // works, so we don't have a clean API for setting 1 key=value pair. We'll
        // just dig into the internals instead
        var p = self.req.params;
        p.names[p.len] = name;
        p.values[p.len] = value;
        p.len += 1;
    }

    pub fn header(self: *Testing, name: []const u8, value: []const u8) void {
        const lower = self.arena.alloc(u8, name.len) catch unreachable;
        _ = std.ascii.lowerString(lower, name);
        self.req.headers.add(lower, value);
    }

    pub fn body(self: *Testing, bd: []const u8) void {
        const mutable = self.arena.dupe(u8, bd) catch unreachable;
        self.req.body_buffer = .{ .type = .static, .data = mutable };
        self.req.body_len = bd.len;
    }

    pub fn form(self: *Testing, data: anytype) void {
        var arr = ArrayList(u8).init(self.arena);

        inline for (@typeInfo(@TypeOf(data)).@"struct".fields) |field| {
            const name = escapeString(self.arena, field.name) catch unreachable;
            const value = escapeString(self.arena, @field(data, field.name)) catch unreachable;
            arr.appendSlice(name) catch unreachable;
            arr.append('=') catch unreachable;
            arr.appendSlice(value) catch unreachable;
            arr.append('&') catch unreachable;
        }

        const items = arr.items;
        if (items.len == 0) {
            return;
        }

        // strip out the last &
        const bd = items[0 .. items.len - 1];
        self.req.body_buffer = .{ .type = .static, .data = bd };
        self.req.body_len = bd.len;
    }

    pub fn expectGzip(self: *Testing) !void {
        var res = try self.parseResponse();
        if (res.headers.get("Content-Encoding")) |ce| {
            try t.expectString("gzip", ce);
        } else {
            return error.NoContentEncoding;
        }

        var fbs = std.io.fixedBufferStream(res.body);
        var uncompressed = std.ArrayList(u8).init(self.arena);
        try std.compress.gzip.decompress(fbs.reader(), uncompressed.writer());

        res.body = uncompressed.items;
        self.parsed_response = res;
    }

    pub fn expectStatus(self: *const Testing, expected: u16) !void {
        try t.expectEqual(expected, self.res.status);
    }

    pub fn expectBody(self: *Testing, expected: []const u8) !void {
        const pr = try self.parseResponse();
        try t.expectString(expected, pr.body);
    }

    pub fn expectJson(self: *Testing, expected: anytype) !void {
        const pr = try self.parseResponse();
        try pr.expectJson(expected);
    }

    pub fn expectHeader(self: *Testing, name: []const u8, expected: ?[]const u8) !void {
        const pr = try self.parseResponse();
        return pr.expectHeader(name, expected);
    }

    pub fn expectHeaderCount(self: *Testing, expected: u32) !void {
        const pr = try self.parseResponse();
        try t.expectEqual(expected, pr.headers.count());
    }
};

const JsonComparer = struct {
    _arena: std.heap.ArenaAllocator,

    const Diff = struct {
        err: []const u8,
        path: []const u8,
        a: []const u8,
        b: []const u8,
    };

    fn init(allocator: Allocator) JsonComparer {
        return .{
            ._arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: JsonComparer) void {
        self._arena.deinit();
    }

    // Compare by getting the string representation of a and b
    // and then parsing it into a std.json.ValueTree,
    // which can compare Either a or b might already be serialized JSON string.
    fn compare(self: *JsonComparer, a: anytype, b: anytype) !ArrayList(Diff) {
        const allocator = self._arena.allocator();
        var a_bytes: []const u8 = undefined;
        if (comptime isString(@TypeOf(a))) {
            a_bytes = a;
        } else {
            a_bytes = try self.stringify(a);
        }

        var b_bytes: []const u8 = undefined;
        if (comptime isString(@TypeOf(b))) {
            b_bytes = b;
        } else {
            b_bytes = try self.stringify(b);
        }

        const a_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, a_bytes, .{});
        const b_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, b_bytes, .{});
        var diffs = ArrayList(Diff).init(allocator);
        var path = ArrayList([]const u8).init(allocator);
        try self.compareValue(a_value, b_value, &diffs, &path);
        return diffs;
    }

    fn compareValue(self: *JsonComparer, a: std.json.Value, b: std.json.Value, diffs: *ArrayList(Diff), path: *ArrayList([]const u8)) !void {
        const allocator = self._arena.allocator();
        if (!std.mem.eql(u8, @tagName(a), @tagName(b))) {
            diffs.append(self.diff("types don't match", path, @tagName(a), @tagName(b))) catch unreachable;
            return;
        }

        switch (a) {
            .null => {},
            .bool => {
                if (a.bool != b.bool) {
                    diffs.append(self.diff("not equal", path, self.format(a.bool), self.format(b.bool))) catch unreachable;
                }
            },
            .integer => {
                if (a.integer != b.integer) {
                    diffs.append(self.diff("not equal", path, self.format(a.integer), self.format(b.integer))) catch unreachable;
                }
            },
            .float => {
                if (a.float != b.float) {
                    diffs.append(self.diff("not equal", path, self.format(a.float), self.format(b.float))) catch unreachable;
                }
            },
            .number_string => {
                if (!std.mem.eql(u8, a.number_string, b.number_string)) {
                    diffs.append(self.diff("not equal", path, a.number_string, b.number_string)) catch unreachable;
                }
            },
            .string => {
                if (!std.mem.eql(u8, a.string, b.string)) {
                    diffs.append(self.diff("not equal", path, a.string, b.string)) catch unreachable;
                }
            },
            .array => {
                const a_len = a.array.items.len;
                const b_len = b.array.items.len;
                if (a_len != b_len) {
                    diffs.append(self.diff("array length", path, self.format(a_len), self.format(b_len))) catch unreachable;
                    return;
                }
                for (a.array.items, b.array.items, 0..) |a_item, b_item, i| {
                    try path.append(try std.fmt.allocPrint(allocator, "{d}", .{i}));
                    try self.compareValue(a_item, b_item, diffs, path);
                    _ = path.pop();
                }
            },
            .object => {
                var it = a.object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    try path.append(key);
                    if (b.object.get(key)) |b_item| {
                        try self.compareValue(entry.value_ptr.*, b_item, diffs, path);
                    } else {
                        diffs.append(self.diff("field missing", path, key, "")) catch unreachable;
                    }
                    _ = path.pop();
                }
            },
        }
    }

    fn stringify(self: *JsonComparer, value: anytype) ![]const u8 {
        var arr = ArrayList(u8).init(self._arena.allocator());
        try std.json.stringify(value, .{}, arr.writer());
        return arr.items;
    }

    fn diff(self: *JsonComparer, err: []const u8, path: *ArrayList([]const u8), a_rep: []const u8, b_rep: []const u8) Diff {
        const full_path = std.mem.join(self._arena.allocator(), ".", path.items) catch unreachable;
        return .{
            .a = a_rep,
            .b = b_rep,
            .err = err,
            .path = full_path,
        };
    }

    fn format(self: *JsonComparer, value: anytype) []const u8 {
        return std.fmt.allocPrint(self._arena.allocator(), "{}", .{value}) catch unreachable;
    }
};

fn isString(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .Slice => return ptr.child == u8,
            .One => switch (@typeInfo(ptr.child)) {
                .array => |arr| return arr.child == u8,
                else => return false,
            },
            else => return false,
        },
        .array => return false,
        else => return false,
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn escapeString(allocator: Allocator, input: []const u8) ![]const u8 {
    var outsize: usize = 0;
    for (input) |c| {
        outsize += if (isUnreserved(c)) @as(usize, 1) else 3;
    }
    var output = try allocator.alloc(u8, outsize);
    var outptr: usize = 0;

    for (input) |c| {
        if (isUnreserved(c)) {
            output[outptr] = c;
            outptr += 1;
        } else {
            var buf: [2]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{X:0>2}", .{c}) catch unreachable;

            output[outptr + 0] = '%';
            output[outptr + 1] = buf[0];
            output[outptr + 2] = buf[1];
            outptr += 3;
        }
    }
    return output;
}
