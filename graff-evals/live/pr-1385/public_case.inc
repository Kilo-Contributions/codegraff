
test "detect: graff's own view and MCP app snapshots" {
    const html = detect("[Rendered view](/home/u/.graff/views/" ++ hex ++ ".html) — shown").?;
    try testing.expectEqualStrings("html", html.kind);
    try testing.expectEqualStrings("/home/u/.graff/views/" ++ hex ++ ".html", html.path);
    try testing.expectEqualStrings(hex, html.id);
    const app = detect("[MCP app](C:\\Users\\u/.graff/mcp-apps/" ++ hex ++ ".html) — saved\nrest").?;
    try testing.expectEqualStrings("mcp_app", app.kind);
    try testing.expectEqualStrings(hex, app.id);
}
