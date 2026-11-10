//! Model Context Protocol (MCP) server support over the Streamable HTTP
//! transport.
//!
//! `Server` owns a bounded registry of tools, resources, and prompts. Register
//! it as a `POST` route; the handler accepts JSON-RPC 2.0 messages, answers
//! `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`,
//! `resources/read`, `prompts/list`, and `prompts/get`, and returns `202` for
//! notifications. Responses use a single `application/json` body, which the
//! Streamable HTTP transport permits.
//!
//! Registration is startup-only and bounded by `Options.max_tools`,
//! `max_resources`, and `max_prompts`. Request bodies are bounded by the
//! server's `Limits.max_body_bytes` and responses by
//! `Limits.max_response_bytes`.

const types = @import("mcp/types.zig");
const server_mod = @import("mcp/server.zig");

pub const Role = types.Role;
pub const ToolAnnotations = types.ToolAnnotations;
pub const ToolContext = types.ToolContext;
pub const ToolHandler = types.ToolHandler;
pub const Tool = types.Tool;
pub const Resource = types.Resource;
pub const PromptArgument = types.PromptArgument;
pub const PromptMessage = types.PromptMessage;
pub const Prompt = types.Prompt;
pub const Options = types.Options;
pub const Server = server_mod.Server;
