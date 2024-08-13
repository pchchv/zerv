const std = @import("std");

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
};

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
