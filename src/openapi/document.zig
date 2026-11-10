const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const types_mod = @import("types.zig");
const render = @import("render.zig");
const ui_mod = @import("ui.zig");

const Handler = handler_mod.Handler;
const RouteView = types_mod.RouteView;
const Options = types_mod.Options;

pub const Document = struct {
    allocator: std.mem.Allocator,
    json: []const u8,
    html: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        routes: []const RouteView,
        options: Options,
    ) !Document {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const root = try render.buildDocument(arena, routes, options);
        const json = try std.json.Stringify.valueAlloc(allocator, root, .{});
        errdefer allocator.free(json);

        var html: ?[]const u8 = null;
        errdefer if (html) |bytes| allocator.free(bytes);
        if (options.ui) |ui| {
            html = try ui_mod.buildUi(allocator, ui, options.info.title);
        }

        return .{
            .allocator = allocator,
            .json = json,
            .html = html,
        };
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.json);
        if (self.html) |html| self.allocator.free(html);
        self.* = undefined;
    }

    /// Serve the rendered OpenAPI JSON document.
    pub fn handler(self: *Document) Handler {
        return handler_mod.withContext(Document, self, serveJson);
    }

    /// Serve the Swagger UI page built from `Options.ui`.
    pub fn uiHandler(self: *Document) Handler {
        return handler_mod.withContext(Document, self, serveUi);
    }

    pub fn jsonBytes(self: *const Document) []const u8 {
        return self.json;
    }

    fn serveJson(self: *Document, ctx: *ctx_mod.Ctx) anyerror!void {
        try ctx.setHeader("Content-Type", "application/json");
        try ctx.text(self.json);
    }

    fn serveUi(self: *Document, ctx: *ctx_mod.Ctx) anyerror!void {
        const html = self.html orelse return error.UiNotConfigured;
        try ctx.setHeader("Content-Type", "text/html; charset=utf-8");
        try ctx.text(html);
    }
};
