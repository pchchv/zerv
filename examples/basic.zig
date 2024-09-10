const std = @import("std");
const zerv = @import("zerv");

fn index(_: *zerv.Request, res: *zerv.Response) !void {
    res.body =
        \\<!DOCTYPE html>
        \\ <ul>
        \\ <li><a href="/hello?name=Teg">Querystring + text output</a>
        \\ <li><a href="/writer/hello/Ghanima">Path parameter + serialize json object</a>
        \\ <li><a href="/json/hello/Duncan">Path parameter + json writer</a>
        \\ <li><a href="/metrics">Internal metrics</a>
        \\ <li><a href="/form_data">Form Data</a>
        \\ <li><a href="/explicit_write">Explicit Write</a>
    ;
}

fn hello(req: *zerv.Request, res: *zerv.Response) !void {
    const query = try req.query();
    const name = query.get("name") orelse "stranger";
    // Could also see res.writer(), see the writer endpoint for an example
    res.body = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
}

fn json(req: *zerv.Request, res: *zerv.Response) !void {
    const name = req.param("name").?;
    // the last parameter to res.json is an std.json.StringifyOptions
    try res.json(.{ .hello = name }, .{});
}

fn writer(req: *zerv.Request, res: *zerv.Response) !void {
    res.content_type = zerv.ContentType.JSON;

    const name = req.param("name").?;
    var ws = std.json.writeStream(res.writer(), .{ .whitespace = .indent_4 });
    try ws.beginObject();
    try ws.objectField("name");
    try ws.write(name);
    try ws.endObject();
}

fn metrics(_: *zerv.Request, res: *zerv.Response) !void {
    // zerv exposes some prometheus-style metrics
    return zerv.writeMetrics(res.writer());
}

fn explicitWrite(_: *zerv.Request, res: *zerv.Response) !void {
    res.body =
        \\ There may be cases where your response is tied to data which
        \\ required cleanup. If `res.arena` and `res.writer()` can't solve
        \\ the issue, you can always call `res.write()` explicitly
    ;
    return res.write();
}
