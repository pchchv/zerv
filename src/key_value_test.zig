const t = @import("test.zig");
const kval = @import("key_value.zig");

const KeyValue = kval.KeyValue;
const MultiFormKeyValue = kval.MultiFormKeyValue;

test "KeyValue: get" {
    var kv = try KeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);

    var key = "content-type".*;
    kv.add(&key, "application/json");

    try t.expectEqual("application/json", kv.get("content-type").?);

    kv.reset();
    try t.expectEqual(null, kv.get("content-type"));
    kv.add(&key, "application/json2");
    try t.expectEqual("application/json2", kv.get("content-type").?);
}

test "KeyValue: ignores beyond max" {
    var kv = try KeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);
    var n1 = "content-length".*;
    kv.add(&n1, "cl");

    var n2 = "host".*;
    kv.add(&n2, "www");

    var n3 = "authorization".*;
    kv.add(&n3, "hack");

    try t.expectEqual("cl", kv.get("content-length").?);
    try t.expectEqual("www", kv.get("host").?);
    try t.expectEqual(null, kv.get("authorization"));

    {
        var it = kv.iterator();
        {
            const field = it.next().?;
            try t.expectString("content-length", field.key);
            try t.expectString("cl", field.value);
        }

        {
            const field = it.next().?;
            try t.expectString("host", field.key);
            try t.expectString("www", field.value);
        }
        try t.expectEqual(null, it.next());
    }
}

test "MultiFormKeyValue: get" {
    var kv = try MultiFormKeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);

    var key = "username".*;
    kv.add(&key, .{ .value = "leto" });

    try t.expectEqual("leto", kv.get("username").?.value);

    kv.reset();
    try t.expectEqual(null, kv.get("username"));
    kv.add(&key, .{ .value = "leto2" });
    try t.expectEqual("leto2", kv.get("username").?.value);
}

test "MultiFormKeyValue: ignores beyond max" {
    var kv = try MultiFormKeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);

    var n1 = "username".*;
    kv.add(&n1, .{ .value = "leto" });

    var n2 = "password".*;
    kv.add(&n2, .{ .value = "ghanima" });

    var n3 = "other".*;
    kv.add(&n3, .{ .value = "hack" });

    try t.expectEqual("leto", kv.get("username").?.value);
    try t.expectEqual("ghanima", kv.get("password").?.value);
    try t.expectEqual(null, kv.get("other"));

    {
        var it = kv.iterator();
        {
            const field = it.next().?;
            try t.expectString("username", field.key);
            try t.expectString("leto", field.value.value);
        }

        {
            const field = it.next().?;
            try t.expectString("password", field.key);
            try t.expectString("ghanima", field.value.value);
        }
        try t.expectEqual(null, it.next());
    }
}
