//! OpenAPI 3.1 document generation from route metadata.
//!
//! Attach `Operation` metadata to `RouteOptions.openapi`, project the router
//! with `Router.openapiRoutes`, and build a `Document` that serves the JSON
//! document and an optional Swagger UI page.

const types = @import("openapi/types.zig");
const document_mod = @import("openapi/document.zig");

pub const Schema = types.Schema;
pub const Property = types.Property;
pub const ParameterLocation = types.ParameterLocation;
pub const Parameter = types.Parameter;
pub const RequestBody = types.RequestBody;
pub const Response = types.Response;
pub const HeaderDescription = types.HeaderDescription;
pub const Operation = types.Operation;
pub const RouteView = types.RouteView;
pub const Contact = types.Contact;
pub const License = types.License;
pub const Info = types.Info;
pub const Server = types.Server;
pub const Tag = types.Tag;
pub const SecuritySchemeKind = types.SecuritySchemeKind;
pub const SecurityScheme = types.SecurityScheme;
pub const UiOptions = types.UiOptions;
pub const Options = types.Options;
pub const Document = document_mod.Document;
