const std = @import("std");

pub const Schema = struct {
    /// JSON Schema type: `object`, `array`, `string`, `integer`, `number`,
    /// `boolean`, or null for a free-form schema.
    type: ?[]const u8 = null,
    format: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Object properties. Ignored unless `type` is `object`.
    properties: []const Property = &.{},
    /// Required property names for object schemas.
    required: []const []const u8 = &.{},
    /// Element schema for `array`.
    items: ?*const Schema = null,
    /// Allowed string values.
    enum_values: []const []const u8 = &.{},
    /// Raw JSON value copied into `example`.
    example_json: ?[]const u8 = null,
    /// Raw JSON value copied into `default`.
    default_json: ?[]const u8 = null,
    /// Emit `[type, "null"]` for the type.
    nullable: bool = false,
    /// Emit `additionalProperties: false` when false.
    additional_properties: bool = true,
    /// Complete JSON schema object. Replaces the generated object.
    raw_json: ?[]const u8 = null,
};

pub const Property = struct {
    name: []const u8,
    schema: Schema = .{},
};

pub const ParameterLocation = enum {
    query,
    header,
    path,
    cookie,

    pub fn jsonName(self: ParameterLocation) []const u8 {
        return @tagName(self);
    }
};

pub const Parameter = struct {
    name: []const u8,
    location: ParameterLocation = .query,
    description: ?[]const u8 = null,
    /// Path parameters are always required regardless of this value.
    required: ?bool = null,
    schema: Schema = .{ .type = "string" },
    example_json: ?[]const u8 = null,
};

pub const RequestBody = struct {
    description: ?[]const u8 = null,
    required: bool = false,
    content_type: []const u8 = "application/json",
    schema: Schema = .{ .type = "object" },
};

pub const Response = struct {
    status: u16 = 200,
    description: []const u8 = "OK",
    /// Null means the response has no body.
    content_type: ?[]const u8 = null,
    schema: ?Schema = null,
    /// Response header names to descriptions.
    headers: []const HeaderDescription = &.{},
};

pub const HeaderDescription = struct {
    name: []const u8,
    description: []const u8,
};

pub const Operation = struct {
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    deprecated: bool = false,
    /// Explicit parameters. Path captures are generated automatically; an
    /// explicit `path` parameter with the same name replaces the generated
    /// schema.
    parameters: []const Parameter = &.{},
    request_body: ?RequestBody = null,
    /// Responses keyed by status. Empty means `200 OK` without a body.
    responses: []const Response = &.{},
    /// Security requirement scheme names (each with no scopes).
    security: []const []const u8 = &.{},
    /// Keep the route out of the document.
    hidden: bool = false,
};

/// One registered route as seen by the document builder. `method` is the
/// uppercase method name; null means the route matches every method.
pub const RouteView = struct {
    method: ?[]const u8,
    pattern: []const u8,
    operation: ?Operation = null,
};

pub const Contact = struct {
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const License = struct {
    name: []const u8,
    identifier: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const Info = struct {
    title: []const u8,
    version: []const u8 = "0.1.0",
    description: ?[]const u8 = null,
    terms_of_service: ?[]const u8 = null,
    contact: ?Contact = null,
    license: ?License = null,
};

pub const Server = struct {
    url: []const u8,
    description: ?[]const u8 = null,
};

pub const Tag = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const SecuritySchemeKind = enum {
    http,
    api_key,
    open_id_connect,
    oauth2,
    mutual_tls,
};

pub const SecurityScheme = struct {
    name: []const u8,
    kind: SecuritySchemeKind = .http,
    description: ?[]const u8 = null,
    /// HTTP authentication scheme: `bearer` or `basic`.
    scheme: ?[]const u8 = null,
    bearer_format: ?[]const u8 = null,
    /// API-key location: `header`, `query`, or `cookie`.
    location: ?[]const u8 = null,
    parameter_name: ?[]const u8 = null,
    /// OpenID Connect discovery URL.
    open_id_connect_url: ?[]const u8 = null,
    /// Complete JSON scheme object. Replaces the generated object.
    raw_json: ?[]const u8 = null,
};

pub const UiOptions = struct {
    title: ?[]const u8 = null,
    /// URL the browser uses to fetch the generated document.
    json_url: []const u8 = "/openapi.json",
    swagger_css_url: []const u8 = "https://unpkg.com/swagger-ui-dist@5/swagger-ui.css",
    swagger_js_url: []const u8 = "https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js",
};

pub const Options = struct {
    info: Info,
    servers: []const Server = &.{},
    tags: []const Tag = &.{},
    security_schemes: []const SecurityScheme = &.{},
    /// Raw JSON array for the document-level `security` field.
    security_json: ?[]const u8 = null,
    /// Include routes whose operation is marked `hidden`.
    include_hidden: bool = false,
    /// Methods emitted for `router.any` routes. Explicit routes on the same
    /// path take precedence.
    any_methods: []const []const u8 = &.{
        "get",
        "post",
        "put",
        "patch",
        "delete",
    },
    /// Build a Swagger UI page served by `uiHandler`.
    ui: ?UiOptions = null,
};
