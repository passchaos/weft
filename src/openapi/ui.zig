const std = @import("std");
const types = @import("types.zig");

const UiOptions = types.UiOptions;

pub fn buildUi(
    allocator: std.mem.Allocator,
    ui: UiOptions,
    document_title: []const u8,
) ![]const u8 {
    const title = ui.title orelse document_title;
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try output.appendSlice("<!doctype html>\n<html lang=\"en\">\n<head>\n");
    try output.appendSlice("<meta charset=\"utf-8\">\n");
    try output.appendSlice("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try appendHtmlEscaped(&output, title);
    try output.appendSlice("</title>\n<link rel=\"stylesheet\" href=\"");
    try appendHtmlEscaped(&output, ui.swagger_css_url);
    try output.appendSlice("\">\n</head>\n<body>\n<div id=\"swagger-ui\"></div>\n<script src=\"");
    try appendHtmlEscaped(&output, ui.swagger_js_url);
    try output.appendSlice("\"></script>\n<script>SwaggerUIBundle({url: \"");
    try appendHtmlEscaped(&output, ui.json_url);
    try output.appendSlice("\", dom_id: \"#swagger-ui\"});</script>\n</body>\n</html>\n");
    return output.toOwnedSlice();
}

fn appendHtmlEscaped(output: *std.array_list.Managed(u8), bytes: []const u8) !void {
    for (bytes) |byte| {
        switch (byte) {
            '&' => try output.appendSlice("&amp;"),
            '<' => try output.appendSlice("&lt;"),
            '>' => try output.appendSlice("&gt;"),
            '"' => try output.appendSlice("&quot;"),
            '\'' => try output.appendSlice("&#39;"),
            else => try output.append(byte),
        }
    }
}
