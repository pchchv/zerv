// Internal helpers used by this library
const std = @import("std");

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}
