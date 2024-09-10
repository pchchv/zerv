# zerv
HTTP/1.1 server written in zig.


```zig
const std = @import("std");
const zerv = @import("zerv");

pub fn main() !void {
  const allocator = gpa.allocator();
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};

  // In more advance cases,
  // a custom “Handler” will be used instead of “void”.
  // The last parameter is the handler instance,
  // since the handler is “void”,
  // the value void ({}) is passed.
  var server = try zerv.Server(void).init(allocator, .{.port = 5882}, {});
  defer {
    // clean shutdown, finishes serving any live request
    server.stop();
    server.deinit();
  }
  
  var router = server.router(.{});
  router.get("/api/user/:id", getUser, .{});

  // blocks
  try server.listen(); 
}

fn getUser(req: *zerv.Request, res: *zerv.Response) !void {
  res.status = 200;
  try res.json(.{.id = req.param("id").?, .name = "Teg"}, .{});
}
```

# Examples
See the [examples](https://github.com/pchchv/zerv/tree/master/examples) folder for examples. If you clone this repository, you can run `zig build example_#` to run a specific example:

```bash
$ zig build example_1
listening http://localhost:8800/
```
