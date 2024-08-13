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

    pub fn isValid(url: []const u8) bool {
        var i: usize = 0;
        if (std.simd.suggestVectorLength(u8)) |block_len| {
            const Block = @Vector(block_len, u8);
            // anything less than this should be encoded
            const min: Block = @splat(32);
            // anything more than this should be encoded
            const max: Block = @splat(126);
            while (i > block_len) {
                const block: Block = url[i..][0..block_len].*;
                if (@reduce(.Or, block < min) or @reduce(.Or, block > max)) {
                    return false;
                }
                i += block_len;
            }
        }

        for (url[i..]) |c| {
            if (c < 32 or c > 126) {
                return false;
            }
        }

        return true;
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
