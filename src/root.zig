//! weft is the application weaving layer on top of netz.
//!
//! It provides a concrete handler contract, middleware chain, method/path
//! router, typed request locals, decoded query and path captures, and bounded
//! HTTP/1, HTTP/2, and HTTP/3 server adapters. Protocol I/O stays in netz; the
//! runtime seam stays `std.Io`.

pub const netz = @import("netz");

pub const Limits = @import("limits.zig").Limits;
pub const Header = @import("response.zig").Header;
pub const Response = @import("response.zig").Response;
pub const reasonFor = @import("response.zig").reasonFor;
pub const validateHeaderName = @import("response.zig").validateHeaderName;
pub const validateHeaderValue = @import("response.zig").validateHeaderValue;

pub const Ctx = @import("ctx.zig").Ctx;
pub const BodyReader = @import("body.zig").BodyReader;
pub const StreamBody = @import("stream.zig").Body;
pub const StreamWriter = @import("stream.zig").Writer;
pub const stream = @import("stream.zig");
pub const sse = @import("sse.zig");
pub const SseEvent = @import("sse.zig").Event;
pub const websocket = @import("websocket.zig");
pub const WebSocketSession = @import("websocket.zig").Session;
pub const WebSocketUpgrade = @import("websocket.zig").Upgrade;
pub const Handler = @import("handler.zig").Handler;
pub const Locals = @import("handler.zig").Locals;
pub const Param = @import("handler.zig").Param;
pub const Protocol = @import("handler.zig").Protocol;
pub const ClientInfo = @import("handler.zig").ClientInfo;
pub const QueryPair = @import("query.zig").Pair;
pub const max_params = @import("handler.zig").max_params;
pub const handler = @import("handler.zig").handler;
pub const handlerFor = @import("handler.zig").handlerFor;
pub const withContext = @import("handler.zig").withContext;

pub const RouteFailure = @import("dispatch.zig").RouteFailure;
pub const query = @import("query.zig");
pub const cookie = @import("cookie.zig");
pub const accept = @import("accept.zig");
pub const multipart = @import("multipart.zig");
pub const MultipartPart = @import("multipart.zig").Part;
pub const MultipartForm = @import("multipart.zig").Form;
pub const multipart_stream = @import("multipart_stream.zig");
pub const MultipartStream = @import("multipart_stream.zig").Stream;
pub const MultipartStreamPart = @import("multipart_stream.zig").Part;
pub const StaticFiles = @import("static_files.zig").StaticFiles;
pub const MimeType = @import("static_files.zig").MimeType;
pub const default_mime_types = @import("static_files.zig").default_mime_types;
pub const SetCookie = @import("cookie.zig").SetCookie;
pub const SameSite = @import("cookie.zig").SameSite;
pub const Route = @import("router.zig").Route;
pub const RouteOptions = @import("router.zig").RouteOptions;
pub const GroupOptions = @import("router.zig").GroupOptions;
pub const Match = @import("router.zig").Match;
pub const Prepared = @import("router.zig").Prepared;
pub const AllowedMethods = @import("router.zig").AllowedMethods;
pub const Resolution = @import("router.zig").Resolution;
pub const Router = @import("router.zig").Router;
pub const max_path_segments = @import("router.zig").max_path_segments;
pub const max_allowed_methods = @import("router.zig").max_allowed_methods;

pub const Options = @import("server.zig").Options;
pub const Server = @import("server.zig").Server;
pub const Http2Options = @import("http2_server.zig").Options;
pub const Http2Server = @import("http2_server.zig").Http2Server;
pub const Http3Options = @import("http3_server.zig").Options;
pub const Http3Server = @import("http3_server.zig").Http3Server;

pub const middleware = @import("middleware/mod.zig");
pub const logging = @import("logging.zig");
pub const openapi = @import("openapi.zig");
pub const mcp = @import("mcp.zig");

comptime {
    _ = @import("limits.zig");
    _ = @import("response.zig");
    _ = @import("ctx.zig");
    _ = @import("ctx_test.zig");
    _ = @import("body.zig");
    _ = @import("handler.zig");
    _ = @import("stream.zig");
    _ = @import("sse.zig");
    _ = @import("websocket.zig");
    _ = @import("query.zig");
    _ = @import("cookie.zig");
    _ = @import("accept.zig");
    _ = @import("quality.zig");
    _ = @import("multipart.zig");
    _ = @import("multipart_stream.zig");
    _ = @import("multipart/reader.zig");
    _ = @import("multipart/delimiter.zig");
    _ = @import("precondition.zig");
    _ = @import("static_files.zig");
    _ = @import("static/path.zig");
    _ = @import("static/variants.zig");
    _ = @import("static/range.zig");
    _ = @import("vary.zig");
    _ = @import("target.zig");
    _ = @import("router.zig");
    _ = @import("router_test.zig");
    _ = @import("router/trie.zig");
    _ = @import("server.zig");
    _ = @import("drain.zig");
    _ = @import("dispatch.zig");
    _ = @import("errors.zig");
    _ = @import("http2_server.zig");
    _ = @import("http3_server.zig");
    _ = middleware;
    _ = @import("middleware/compress_test.zig");
    _ = @import("middleware/compress/negotiate.zig");
    _ = @import("middleware/compress/gzip.zig");
    _ = @import("middleware/compress/deflate.zig");
    _ = @import("middleware/compress/brotli.zig");
    _ = @import("middleware/compress/zstd.zig");
    _ = @import("middleware/compress/continuous.zig");
    _ = @import("logging.zig");
    _ = @import("bounded_arena.zig");
    _ = @import("openapi.zig");
    _ = @import("openapi/types.zig");
    _ = @import("openapi/render.zig");
    _ = @import("openapi/ui.zig");
    _ = @import("openapi/document.zig");
    _ = @import("openapi_test.zig");
    _ = @import("mcp.zig");
    _ = @import("mcp/types.zig");
    _ = @import("mcp/server.zig");
    _ = @import("mcp_test.zig");
    _ = @import("adapter/body.zig");
    _ = @import("adapter/header_view.zig");
    _ = @import("adapter/response.zig");
    _ = @import("adapter/write.zig");
}
