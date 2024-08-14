const std = @import("std");
const t = @import("test.zig");
const Url = @import("url.zig").Url;

test "url: parse" {
    {
        // absolute root
        const url = Url.parse("/");
        try t.expectString("/", url.raw);
        try t.expectString("/", url.path);
        try t.expectString("", url.query);
    }

    {
        // absolute path
        const url = Url.parse("/a/bc/def");
        try t.expectString("/a/bc/def", url.raw);
        try t.expectString("/a/bc/def", url.path);
        try t.expectString("", url.query);
    }

    {
        // absolute root with query
        const url = Url.parse("/?over=9000");
        try t.expectString("/?over=9000", url.raw);
        try t.expectString("/", url.path);
        try t.expectString("over=9000", url.query);
    }

    {
        // absolute root with empty query
        const url = Url.parse("/?");
        try t.expectString("/?", url.raw);
        try t.expectString("/", url.path);
        try t.expectString("", url.query);
    }

    {
        // absolute path with query
        const url = Url.parse("/hello/teg?duncan=idaho&ghanima=atreides");
        try t.expectString("/hello/teg?duncan=idaho&ghanima=atreides", url.raw);
        try t.expectString("/hello/teg", url.path);
        try t.expectString("duncan=idaho&ghanima=atreides", url.query);
    }
}

test "url: unescape" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var buffer: [10]u8 = undefined;

    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%a"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%1"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "123%45%6"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%zzzzz"));

    var res = try Url.unescape(allocator, &buffer, "a+b");
    try t.expectString("a b", res.value);
    try t.expectEqual(true, res.buffered);

    res = try Url.unescape(allocator, &buffer, "a%20b");
    try t.expectString("a b", res.value);
    try t.expectEqual(true, res.buffered);

    const input = "%5C%C3%B6%2F%20%C3%A4%C3%B6%C3%9F%20~~.adas-https%3A%2F%2Fcanvas%3A123%2F%23ads%26%26sad";
    const expected = "\\ö/ äöß ~~.adas-https://canvas:123/#ads&&sad";
    res = try Url.unescape(allocator, &buffer, input);
    try t.expectString(expected, res.value);
    try t.expectEqual(false, res.buffered);
}

test "url: isValid" {
    var input: [600]u8 = undefined;
    for ([_]u8{ ' ', 'a', 'Z', '~' }) |c| {
        @memset(&input, c);
        for (0..input.len) |i| {
            try t.expectEqual(true, Url.isValid(input[0..i]));
        }
    }

    var r = t.getRandom();
    const random = r.random();

    for ([_]u8{ 31, 128, 0, 255 }) |c| {
        for (1..input.len) |i| {
            var slice = input[0..i];
            const idx = random.uintAtMost(usize, slice.len - 1);
            slice[idx] = c;
            try t.expectEqual(false, Url.isValid(slice));
            slice[idx] = 'a'; // revert this index to a valid value
        }
    }
}
