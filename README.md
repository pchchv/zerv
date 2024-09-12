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

# Installation
1) Add zerv as a dependency in your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/pchchv/zerv#master
```

2) In your `build.zig`, add the `zerv` module as a dependency you your program:

```zig
const zerv = b.dependency("zerv", .{
    .target = target,
    .optimize = optimize,
});

// the executable from your call to b.addExecutable(...)
exe.root_module.addImport("zerv", zerv.module("zerv"));
```

## Why not std.http.Server
`std.http.Server` is very slow and assumes well-behaved clients.

There are many implementations of the Zig HTTP server. Most of them bypass `std.http.Server` and tend to be slow. Benchmarks will help to verify this.  It should be canceled that some wrap C libraries and run faster.  

zerv is written in Zig, without using `std.http.Server`. On M2, a basic request can reach 140K requests per second.

# Handler
When a non-void Handler is used, the value given to `Server(H).init` is passed to every action. This is how application-specific data can be passed into your actions.

For example, using [pg.zig](https://github.com/pchchv/pg.zig), we can make a database connection pool available to each action:

```zig
const pg = @import("pg");
const std = @import("std");
const zerv = @import("zerv");

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();

  var db = try pg.Pool.init(allocator, .{
    .connect = .{ .port = 5432, .host = "localhost"},
    .auth = .{.username = "user", .database = "db", .password = "pass"}
  });
  defer db.deinit();

  var app = App{
    .db = db,
  };

  var server = try zerv.Server(*App).init(allocator, .{.port = 5882}, &app);
  var router = server.router(.{});
  router.get("/api/user/:id", getUser, .{});
  try server.listen();
}

const App = struct {
    db: *pg.Pool,
};

fn getUser(app: *App, req: *zerv.Request, res: *zerv.Response) !void {
  const user_id = req.param("id").?;

  var row = try app.db.row("select name from users where id = $1", .{user_id}) orelse {
    res.status = 404;
    res.body = "Not found";
    return;
  };
  defer row.deinit() catch {};

  try res.json(.{
    .id = user_id,
    .name = row.get([]u8, 0),
  }, .{});
}
```

## Custom Dispatch
Beyond sharing state, your custom handler can be used to control how zerv behaves. By defining a public `dispatch` method you can control how (or even **if**) actions are executed. For example, to log timing, you could do:

```zig
const App = struct {
  pub fn dispatch(self: *App, action: zerv.Action(*App), req: *zerv.Request, res: *zerv.Response) !void {
    var timer = try std.time.Timer.start();

    // your `dispatch` doesn't _have_ to call the action
    try action(self, req, res);

    const elapsed = timer.lap() / 1000; // ns -> us
    std.log.info("{} {s} {d}", .{req.method, req.url.path, elapsed});
  }
};
```

### Per-Request Context
The 2nd parameter, `action`, is of type `zerv.Action(*App)`. This is a function pointer to the function you specified when setting up the routes. As we've seen, this works well to share global data. But, in many cases, you'll want to have request-specific data.

Consider the case where you want your `dispatch` method to conditionally load a user (maybe from the `Authorization` header of the request). How would you pass this `User` to the action? You can't use the `*App` directly, as this is shared concurrently across all requests.

To achieve this, we'll add another structure called `RequestContext`. You can call this whatever you want, and it can contain any fields of methods you want.

```zig
const RequestContext = struct {
  // You don't have to put a reference to your global data.
  // But chances are you'll want.
  app: *App,
  user: ?User,
};
```

We can now change the definition of our actions and `dispatch` method:

```zig
fn getUser(ctx: *RequestContext, req: *zerv.Request, res: *zerv.Response) !void {
   // can check if ctx.user is != null
}

const App = struct {
  pub fn dispatch(self: *App, action: zerv.Action(*RequestContext), req: *zerv.Request, res: *zerv.Response) !void {
    var ctx = RequestContext{
      .app = self,
      .user = self.loadUser(req),
    }
    return action(&ctx, req, res);
  }

  fn loadUser(self: *App, req: *zerv.Request) ?User {
    // todo, maybe using req.header("authorizaation")
  }
};

```

zerv infers the type of the action based on the 2nd parameter of your handler's `dispatch` method. If you use a `void` handler or your handler doesn't have a `dispatch` method, then you won't interact with `zerv.Action(H)` directly.

## Not Found
If your handler has a public `notFound` method, it will be called whenever a path doesn't match a found route:

```zig
const App = struct {
  pub fn notFound(_: *App, req: *zerv.Request, res: *zerv.Response) !void {
    std.log.info("404 {} {s}", .{req.method, req.url.path});
    res.status = 404;
    res.body = "Not Found";
  }
};
```

## Error Handler
If your handler has a public `uncaughtError` method, it will be called whenever there's an unhandled error. This could be due to some internal zerv bug, or because your action return an error. 

```zig
const App = struct {
  pub fn uncaughtError(self: *App, _: *Request, res: *Response, err: anyerror) void {
    std.log.info("500 {} {s} {}", .{req.method, req.url.path, err});
    res.status = 500;
    res.body = "sorry";
  }
};
```

Notice that, unlike `notFound` and other normal actions, the `uncaughtError` method cannot return an error itself.

## Takeover
For the most control, you can define a `handle` method. This circumvents most of zerv's dispatching, including routing. Frameworks like JetZig hook use `handle` in order to provide their own routing and dispatching. When you define a `handle` method, then any `dispatch`, `notFound` and `uncaughtError` methods are ignored by zerv.

```zig
const App = struct {
  pub fn handle(app: *App, req: *Request, res: *Response) void {
    // todo
  }
};
```

The behavior `zerv.Server(H)` is controlled by 
The library supports both simple and complex use cases. A simple use case is shown below. It's initiated by the call to `zerv.Server()`:

```zig
const std = @import("std");
const zerv = @import("zerv");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try zerv.Server().init(allocator, .{.port = 5882});
    
    // overwrite the default notFound handler
    server.notFound(notFound);

    // overwrite the default error handler
    server.errorHandler(errorHandler); 

    var router = server.router(.{});

    // use get/post/put/head/patch/options/delete
    // you can also use "all" to attach to all methods
    router.get("/api/user/:id", getUser, .{});

    // start the server in the current thread, blocking.
    try server.listen(); 
}

fn getUser(req: *zerv.Request, res: *zerv.Response) !void {
    // status code 200 is implicit. 

    // The json helper will automatically set the res.content_type = zerv.ContentType.JSON;
    // Here we're passing an inferred anonymous structure, but you can pass anytype 
    // (so long as it can be serialized using std.json.stringify)

    try res.json(.{.id = req.param("id").?, .name = "Teg"}, .{});
}

fn notFound(_: *zerv.Request, res: *zerv.Response) !void {
    res.status = 404;

    // you can set the body directly to a []u8, but note that the memory
    // must be valid beyond your handler. Use the res.arena if you need to allocate
    // memory for the body.
    res.body = "Not Found";
}

// note that the error handler return `void` and not `!void`
fn errorHandler(req: *zerv.Request, res: *zerv.Response, err: anyerror) void {
    res.status = 500;
    res.body = "Internal Server Error";
    std.log.warn("zerv: unhandled exception for request: {s}\nErr: {}", .{req.url.raw, err});
}
```

# Memory and Arenas
Any allocations made for the response, such as the body or a header, must remain valid until **after** the action returns. To achieve this, use `res.arena` or the `res.writer()`:

```zig
fn arenaExample(req: *zerv.Request, res: *zerv.Response) !void {
    const query = try req.query();
    const name = query.get("name") orelse "stranger";
    res.body = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
}

fn writerExample(req: *zerv.Request, res: *zerv.Response) !void {
    const query = try req.query();
    const name = query.get("name") orelse "stranger";
    try std.fmt.format(res.writer(), "Hello {s}", .{name});
}
```

Alternatively, you can explicitly call `res.write()`. Once `res.write()` returns, the response is sent and your action can cleanup/release any resources.

`res.arena` is actually a configurable-sized thread-local buffer that fallsback to an `std.heap.ArenaAllocator`. In other words, it's fast so it should be your first option for data that needs to live only until your action exits.

# zerv.Request
The following fields are the most useful:

* `method` - an zerv.Method enum
* `arena` - A fast thread-local buffer that fallsback to an ArenaAllocator, same as `res.arena`.
* `url.path` - the path of the request (`[]const u8`)
* `address` - the std.net.Address of the client

If you give your route a `data` configuration, the value can be retrieved from the optional `route_data` field of the request.

## Path Parameters
The `param` method of `*Request` returns an `?[]const u8`. For example, given the following path:

```zig
router.get("/api/users/:user_id/favorite/:id", user.getFavorite, .{});
```

Then we could access the `user_id` and `id` via:

```zig
pub fn getFavorite(req *http.Request, res: *http.Response) !void {
    const user_id = req.param("user_id").?;
    const favorite_id = req.param("id").?;
    ...
```

In the above, passing any other value to `param` would return a null object (since the route associated with `getFavorite` only defines these 2 parameters). Given that routes are generally statically defined, it should not be possible for `req.param` to return an unexpected null. However, it *is* possible to define two routes to the same action:

```zig
router.put("/api/users/:user_id/favorite/:id", user.updateFavorite, .{});

// currently logged in user, maybe?
router.put("/api/use/favorite/:id", user.updateFavorite, .{});
```

In which case the optional return value of `param` might be useful.

## Header Values
Similar to `param`, header values can be fetched via the `header` function, which also returns a `?[]const u8`:

```zig
if (req.header("authorization")) |auth| {

} else { 
    // not logged in?:
}
```

Header names are lowercase. Values maintain their original casing.

To iterate over all headers, use:

```zig
var it = req.headers.iterator();
while (it.next()) |kv| {
  // kv.key
  // kv.value
}
```

## QueryString
The framework does not automatically parse the query string. Therefore, its API is slightly different.

```zig
const query = try req.query();
if (query.get("search")) |search| {

} else {
    // no search parameter
};
```

On first call, the `query` function attempts to parse the querystring. This requires memory allocations to unescape encoded values. The parsed value is internally cached, so subsequent calls to `query()` are fast and cannot fail.

The original casing of both the key and the name are preserved.

To iterate over all query parameters, use:

```zig
var it = req.query().iterator();
while (it.next()) |kv| {
  // kv.key
  // kv.value
}
```

## Body
The body of the request, if any, can be accessed using `req.body()`. This returns a `?[]const u8`.

### Json Body
The `req.json(TYPE)` function is a wrapper around the `body()` function which will call `std.json.parse` on the body. This function does not consider the content-type of the request and will try to parse any body.

```zig
if (try req.json(User)) |user| {

}
```

### JsonValueTree Body
The `req.jsonValueTree()` function is a wrapper around the `body()` function which will call `std.json.Parse` on the body, returning a `!?std.jsonValueTree`. This function does not consider the content-type of the request and will try to parse any body.

```zig
if (try req.jsonValueTree()) |t| {
    // probably want to be more defensive than this
    const product_type = r.root.Object.get("type").?.String;
    //...
}
```

### JsonObject Body
The even more specific `jsonObject()` function will return an `std.json.ObjectMap` provided the body is a map

```zig
if (try req.jsonObject()) |t| {
    // probably want to be more defensive than this
    const product_type = t.get("type").?.String;
    //...
}
```

## Form Data
The body of the request, if any, can be parsed as a "x-www-form-urlencoded "value  using `req.formData()`. The `request.max_form_count` configuration value must be set to the maximum number of form fields to support. This defaults to 0.

This behaves similarly to `query()`.

On first call, the `formData` function attempts to parse the body. This can require memory allocations to unescape encoded values. The parsed value is internally cached, so subsequent calls to `formData()` are fast and cannot fail.

The original casing of both the key and the name are preserved.

To iterate over all fields, use:

```zig
var it = (try req.formData()).iterator();
while (it.next()) |kv| {
  // kv.key
  // kv.value
}
```

Once this function is called, `req.multiFormData()` will no longer work (because the body is assumed parsed).

## Multi Part Form Data
Similar to the above, `req.multiFormData()` can be called to parse requests with a "multipart/form-data" content type. The `request.max_multiform_count` configuration value must be set to the maximum number of form fields to support. This defaults to 0.

This is a different API than `formData` because the return type is different. Rather than a simple string=>value type, the multi part form data value consists of a `value: []const u8` and a `filename: ?[]const u8`.

On first call, the `multiFormData` function attempts to parse the body. The parsed value is internally cached, so subsequent calls to `multiFormData()` are fast and cannot fail.

The original casing of both the key and the name are preserved.

To iterate over all fields, use:

```zig
var it = req.multiFormData.iterator();
while (it.next()) |kv| {
  // kv.key
  // kv.value.value
  // kv.value.filename (optional)
}
```

Once this function is called, `req.formData()` will no longer work (because the body is assumed parsed).

Advance warning: This is one of the few methods that can modify the request in-place. For most people this won't be an issue, but if you use `req.body()` and `req.multiFormData()`, say to log the raw body, the content-disposition field names are escaped in-place. It's still safe to use `req.body()` but any  content-disposition name that was escaped will be a little off.

# zerv.Response
The following fields are the most useful:

* `status` - set the status code, by default, each response starts off with a 200 status code
* `content_type` - an zerv.ContentType enum value. This is a convenience and optimization over using the `res.header` function.
* `arena` - A fast thread-local buffer that fallsback to an ArenaAllocator, same as `req.arena`.

## Body
The simplest way to set a body is to set `res.body` to a `[]const u8`. **However** the provided value must remain valid until the body is written, which happens after the function exists or when `res.write()` is explicitly called.

## Dynamic Content
You can use the `res.arena` allocator to create dynamic content:

```zig
const query = try req.query();
const name = query.get("name") orelse "stranger";
res.body = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
```

Memory allocated with `res.arena` will exist until the response is sent.

## io.Writer
`res.writer()` returns an `std.io.Writer`. Various types support writing to an io.Writer. For example, the built-in JSON stream writer can use this writer:

```zig
var ws = std.json.writeStream(res.writer(), 4);
try ws.beginObject();
try ws.objectField("name");
try ws.emitString(req.param("name").?);
try ws.endObject();
```

## JSON
The `res.json` function will set the content_type to `zerv.ContentType.JSON` and serialize the provided value using `std.json.stringify`. The 2nd argument to the json function is the `std.json.StringifyOptions` to pass to the `stringify` function.

This function uses `res.writer()` explained above.

## Header Value
Set header values using the `res.header(NAME, VALUE)` function:

```zig
res.header("Location", "/");
```

The header name and value are sent as provided. Both the name and value must remain valid until the response is sent, which will happen outside of the action. Dynamic names and/or values should be created and or dupe'd with `res.arena`. 

`res.headerOpts(NAME, VALUE, OPTS)` can be used to dupe the name and/or value:

```zig
try res.headerOpts("Location", location, .{.dupe_value = true});
```

`HeaderOpts` currently supports `dupe_name: bool` and `dupe_value: bool`, both default to `false`.

## Writing
By default, zerv will automatically flush your response. In more advance cases, you can use `res.write()` to explicitly flush it. This is useful in cases where you have resources that need to be freed/released only after the response is written. For example, my [LRU cache](https://github.com/pchchv/cache.zig) uses atomic referencing counting to safely allow concurrent access to cached data. This requires callers to "release" the cached entry:

```zig
pub fn info(app: *MyApp, _: *zerv.Request, res: *zerv.Response) !void {
    const cached = app.cache.get("info") orelse {
        // load the info
    };
    defer cached.release();

    res.body = cached.value;
    return res.write();
}
```

# Router
You get an instance of the router by calling `server.route(.{})`. Currently, the configuration takes a single parameter:

* `middlewares` - A list of middlewares to apply to each request. These middleware will be executed even for requests with no matching route (i.e. not found). An individual route can opt-out of these middleware, see the `middleware_strategy` route configuration.

You can use the `get`, `put`, `post`, `head`, `patch`, `trace`, `delete` or `options` method of the router to define a router. You can also use the special `all` method to add a route for all methods.

These functions can all `@panic` as they allocate memory. Each function has an equivalent `tryXYZ` variant which will return an error rather than panicking:

```zig
// this can panic if it fails to create the route
router.get("/", index, .{});

// this returns a !void (which you can try/catch)
router.tryGet("/", index, .{});
```

The 3rd parameter is a route configuration. It allows you to speficy a different `handler` and/or `dispatch` method and/or `middleware`.

```zig
// this can panic if it fails to create the route
router.get("/", index, .{
  .dispatcher = Handler.dispathAuth,
  .handler = &auth_handler,
  .middlewares = &.{cors_middleware},
});
```
