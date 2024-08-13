const std = @import("std");

pub const Url = struct {
    raw: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",

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
