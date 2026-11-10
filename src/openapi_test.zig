const std = @import("std");
const openapi = @import("openapi.zig");

const Document = openapi.Document;
const Options = openapi.Options;
const Schema = openapi.Schema;
const Property = openapi.Property;
const Parameter = openapi.Parameter;
const ParameterLocation = openapi.ParameterLocation;
const RequestBody = openapi.RequestBody;
const Response = openapi.Response;
const HeaderDescription = openapi.HeaderDescription;
const Operation = openapi.Operation;
const RouteView = openapi.RouteView;
const Contact = openapi.Contact;
const License = openapi.License;
const Info = openapi.Info;
const Server = openapi.Server;
const Tag = openapi.Tag;
const SecurityScheme = openapi.SecurityScheme;
const SecuritySchemeKind = openapi.SecuritySchemeKind;
const UiOptions = openapi.UiOptions;

test "openapi builds paths, captures, and operations" {
    const allocator = std.testing.allocator;

    const item_schema = Schema{
        .type = "object",
        .properties = &.{
            .{ .name = "id", .schema = .{ .type = "integer" } },
            .{ .name = "name", .schema = .{ .type = "string" } },
        },
        .required = &.{"id"},
    };

    const routes = [_]RouteView{
        .{
            .method = "GET",
            .pattern = "/hello/:name",
            .operation = .{
                .summary = "Greet a caller",
                .operation_id = "greet",
                .tags = &.{"greeting"},
                .parameters = &.{
                    .{
                        .name = "lang",
                        .location = .query,
                        .schema = .{ .type = "string" },
                    },
                },
                .responses = &.{
                    .{
                        .status = 200,
                        .description = "Greeting",
                        .content_type = "application/json",
                        .schema = item_schema,
                    },
                },
            },
        },
        .{
            .method = "POST",
            .pattern = "/items",
            .operation = .{
                .request_body = .{ .required = true },
                .responses = &.{
                    .{ .status = 201, .description = "Created" },
                },
            },
        },
        .{
            .method = "GET",
            .pattern = "/assets/*",
        },
    };

    var document = try Document.init(allocator, &routes, .{
        .info = .{ .title = "weft test", .version = "1.2.3" },
        .security_schemes = &.{
            .{ .name = "bearer", .kind = .http, .scheme = "bearer" },
        },
    });
    defer document.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        document.jsonBytes(),
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings(
        "3.1.0",
        root.get("openapi").?.string,
    );
    try std.testing.expectEqualStrings(
        "weft test",
        root.get("info").?.object.get("title").?.string,
    );

    const paths = root.get("paths").?.object;
    const hello = paths.get("/hello/{name}").?.object.get("get").?.object;
    try std.testing.expectEqualStrings(
        "greet",
        hello.get("operationId").?.string,
    );
    const parameters = hello.get("parameters").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), parameters.len);
    try std.testing.expectEqualStrings(
        "name",
        parameters[0].object.get("name").?.string,
    );
    try std.testing.expectEqualStrings(
        "path",
        parameters[0].object.get("in").?.string,
    );
    try std.testing.expect(
        parameters[0].object.get("required").?.bool,
    );
    try std.testing.expectEqualStrings(
        "lang",
        parameters[1].object.get("name").?.string,
    );

    const items = paths.get("/items").?.object.get("post").?.object;
    try std.testing.expect(
        items.get("requestBody").?.object.get("required").?.bool,
    );
    try std.testing.expect(
        items.get("responses").?.object.get("201") != null,
    );

    const assets = paths.get("/assets/{path}").?.object.get("get").?.object;
    try std.testing.expectEqualStrings(
        "path",
        assets.get("parameters").?.array.items[0].object.get("name").?.string,
    );

    const schemes = root.get("components").?.object
        .get("securitySchemes").?.object;
    try std.testing.expectEqualStrings(
        "http",
        schemes.get("bearer").?.object.get("type").?.string,
    );
}

test "openapi expands any routes without shadowing explicit methods" {
    const allocator = std.testing.allocator;

    const routes = [_]RouteView{
        .{ .method = "GET", .pattern = "/resource" },
        .{ .method = null, .pattern = "/resource" },
    };

    var document = try Document.init(allocator, &routes, .{
        .info = .{ .title = "any" },
        .any_methods = &.{ "get", "post" },
    });
    defer document.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        document.jsonBytes(),
        .{},
    );
    defer parsed.deinit();
    const item = parsed.value.object.get("paths").?.object
        .get("/resource").?.object;
    try std.testing.expect(item.get("get") != null);
    try std.testing.expect(item.get("post") != null);
}

test "openapi rejects invalid raw schema JSON" {
    const allocator = std.testing.allocator;

    const routes = [_]RouteView{
        .{
            .method = "GET",
            .pattern = "/broken",
            .operation = .{
                .responses = &.{
                    .{
                        .status = 200,
                        .description = "Broken",
                        .content_type = "application/json",
                        .schema = .{ .raw_json = "{not json" },
                    },
                },
            },
        },
    };

    try std.testing.expectError(
        error.InvalidJsonMetadata,
        Document.init(allocator, &routes, .{ .info = .{ .title = "bad" } }),
    );
}

test "openapi builds a swagger ui page when configured" {
    const allocator = std.testing.allocator;

    const routes = [_]RouteView{
        .{ .method = "GET", .pattern = "/" },
    };

    var document = try Document.init(allocator, &routes, .{
        .info = .{ .title = "UI <test>" },
        .ui = .{ .json_url = "/openapi.json" },
    });
    defer document.deinit();

    const html = document.html.?;
    try std.testing.expect(
        std.mem.indexOf(u8, html, "UI &lt;test&gt;") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, html, "/openapi.json") != null,
    );
}
