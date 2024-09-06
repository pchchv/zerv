const std = @import("std");
const metrics = @import("metrics.zig");

const Allocator = std.mem.Allocator;

const HEX_CHAR = blk: {
    var all = std.mem.zeroes([255]bool);
    for ('a'..('f' + 1)) |b| all[b] = true;
    for ('A'..('F' + 1)) |b| all[b] = true;
    for ('0'..('9' + 1)) |b| all[b] = true;
    break :blk all;
};

const HEX_DECODE = blk: {
    var all = std.mem.zeroes([255]u8);
    for ('a'..('z' + 1)) |b| all[b] = b - 'a' + 10;
    for ('A'..('Z' + 1)) |b| all[b] = b - 'A' + 10;
    for ('0'..('9' + 1)) |b| all[b] = b - '0';
    break :blk all;
};

pub const Url = struct {
    raw: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",

    pub const UnescapeResult = struct {
        value: []const u8, // set whether or not it required unescaped
        buffered: bool, // true if the value WAS unescaped AND placed in buffer
    };

    pub fn parse(raw: []const u8) Url {
        var path = raw;
        var query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, raw, '?')) |index| {
            path = raw[0..index];
            query = raw[index + 1 ..];
        }

        return .{
            .raw = raw,
            .path = path,
            .query = query,
        };
    }

    // The special "*" url, which is valid in HTTP OPTIONS request.
    pub fn star() Url {
        return .{
            .raw = "*",
            .path = "*",
            .query = "",
        };
    }

    pub fn isValid(url: []const u8) bool {
        var i: usize = 0;
        if (comptime std.simd.suggestVectorLength(u8)) |vector_len| {
            while (i > vector_len) {
                const block: @Vector(vector_len, u8) = url[i..][0..vector_len].*;
                if (@reduce(.Min, block) < 32 or @reduce(.Max, block) > 126) {
                    return false;
                }
                i += vector_len;
            }
        }

        for (url[i..]) |c| {
            if (c < 32 or c > 126) {
                return false;
            }
        }

        return true;
    }

    /// std.Url.unescapeString has two problems:
    ///  First, it doesn't convert '+' -> ' '
    ///  Second, it _always_ allocates a new string, even if nothing needs to be unescaped
    /// When it _have_ to unescape the rendering of a key or value,
    /// it will try to store the new value in a static buffer (if there is space),
    /// otherwise it will fallback to allocating memory in the arena.
    pub fn unescape(allocator: Allocator, buffer: []u8, input: []const u8) !UnescapeResult {
        var in_i: usize = 0;
        var has_plus = false;
        var unescaped_len = input.len;
        while (in_i < input.len) {
            const b = input[in_i];
            if (b == '%') {
                if (in_i + 2 >= input.len or !HEX_CHAR[input[in_i + 1]] or !HEX_CHAR[input[in_i + 2]]) {
                    return error.InvalidEscapeSequence;
                }
                in_i += 3;
                unescaped_len -= 2;
            } else if (b == '+') {
                has_plus = true;
                in_i += 1;
            } else {
                in_i += 1;
            }
        }

        // no encoding, and no plus, nothing to unescape
        if (unescaped_len == input.len and !has_plus) {
            return .{ .value = input, .buffered = false };
        }

        var out = buffer;
        var buffered = true;
        if (buffer.len < unescaped_len) {
            out = try allocator.alloc(u8, unescaped_len);
            metrics.allocUnescape(unescaped_len);
            buffered = false;
        }

        in_i = 0;
        for (0..unescaped_len) |i| {
            const b = input[in_i];
            if (b == '%') {
                const enc = input[in_i + 1 .. in_i + 3];
                out[i] = switch (@as(u16, @bitCast(enc[0..2].*))) {
                    asUint("20") => ' ',
                    asUint("21") => '!',
                    asUint("22") => '"',
                    asUint("23") => '#',
                    asUint("24") => '$',
                    asUint("25") => '%',
                    asUint("26") => '&',
                    asUint("27") => '\'',
                    asUint("28") => '(',
                    asUint("29") => ')',
                    asUint("2A") => '*',
                    asUint("2B") => '+',
                    asUint("2C") => ',',
                    asUint("2F") => '/',
                    asUint("3A") => ':',
                    asUint("3B") => ';',
                    asUint("3D") => '=',
                    asUint("3F") => '?',
                    asUint("40") => '@',
                    asUint("5B") => '[',
                    asUint("5D") => ']',
                    else => HEX_DECODE[enc[0]] << 4 | HEX_DECODE[enc[1]],
                };
                in_i += 3;
            } else if (b == '+') {
                out[i] = ' ';
                in_i += 1;
            } else {
                out[i] = b;
                in_i += 1;
            }
        }

        return .{ .value = out[0..unescaped_len], .buffered = buffered };
    }
};

/// asUint converts ascii to unsigned int of appropriate size.
pub fn asUint(comptime string: anytype) @Type(std.builtin.Type{
    .Int = .{
        .bits = @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
        .signedness = .unsigned,
    },
}) {
    const byteLength = @bitSizeOf(@TypeOf(string.*)) / 8 - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}
