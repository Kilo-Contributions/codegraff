
test "detect: anything else is plain text" {
    try testing.expect(detect("done") == null);
    try testing.expect(detect("see [Rendered view](/home/u/.graff/views/" ++ hex ++ ".html)") == null); // not at the start
    try testing.expect(detect("[Rendered view](/etc/passwd)") == null);
    try testing.expect(detect("[Rendered view](/home/u/.graff/mcp-apps/" ++ hex ++ ".html)") == null); // wrong dir for the kind
    try testing.expect(detect("[MCP app](/home/u/.graff/mcp-apps/" ++ "0123456789ABCDEF0123456789abcdef" ++ ".html)") == null);
    try testing.expect(detect("[MCP app](/home/u/.graff/mcp-apps/short.html)") == null);
    try testing.expect(detect("[Rendered view](/home/u/.graff/views/" ++ hex ++ ".html") == null); // unclosed
}
