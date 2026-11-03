//! weft is the application weaving layer on top of netz.
//!
//! It provides a concrete handler contract, middleware chain, method/path
//! router, typed request locals, decoded query and path captures, and a
//! bounded HTTP/1 server adapter. Protocol I/O stays in netz; the runtime seam
//! stays `std.Io`.

pub const netz = @import("netz");

pub const Limits = @import("limits.zig").Limits;
pub const Header = @import("response.zig").Header;
pub const Response = @import("response.zig").Response;
pub const reasonFor = @import("response.zig").reasonFor;
pub const validateHeaderName = @import("response.zig").validateHeaderName;
pub const validateHeaderValue = @import("response.zig").validateHeaderValue;

pub const Ctx = @import("ctx.zig").Ctx;
pub const Handler = @import("ctx.zig").Handler;
pub const Locals = @import("ctx.zig").Locals;
pub const Param = @import("ctx.zig").Param;
pub const QueryPair = @import("ctx.zig").QueryPair;
pub const max_params = @import("ctx.zig").max_params;
pub const handler = @import("ctx.zig").handler;
pub const handlerFor = @import("ctx.zig").handlerFor;
pub const withContext = @import("ctx.zig").withContext;

pub const query = @import("query.zig");
pub const cookie = @import("cookie.zig");
pub const SetCookie = @import("cookie.zig").SetCookie;
pub const SameSite = @import("cookie.zig").SameSite;
pub const Route = @import("router.zig").Route;
pub const RouteOptions = @import("router.zig").RouteOptions;
pub const GroupOptions = @import("router.zig").GroupOptions;
pub const Match = @import("router.zig").Match;
pub const AllowedMethods = @import("router.zig").AllowedMethods;
pub const Resolution = @import("router.zig").Resolution;
pub const Router = @import("router.zig").Router;
pub const max_path_segments = @import("router.zig").max_path_segments;
pub const max_allowed_methods = @import("router.zig").max_allowed_methods;

pub const Options = @import("server.zig").Options;
pub const Server = @import("server.zig").Server;

pub const middleware = @import("middleware/mod.zig");

comptime {
    _ = @import("limits.zig");
    _ = @import("response.zig");
    _ = @import("ctx.zig");
    _ = @import("query.zig");
    _ = @import("cookie.zig");
    _ = @import("router.zig");
    _ = @import("server.zig");
    _ = middleware;
}
