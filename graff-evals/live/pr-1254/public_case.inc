
test "parse: stdio with args and env, http with headers, sse and malformed left out" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const params = try std.json.parseFromSliceLeaky(Value, a,
        \\{"sessionId":"s","cwd":"/tmp","mcpServers":[
        \\  {"name":"files","command":"/usr/bin/files-mcp","args":["--root","/tmp",7],"env":[{"name":"TOKEN","value":"t"}]},
        \\  {"type":"http","name":"browser","url":"http://127.0.0.1:9/mcp","headers":[{"name":"Authorization","value":"Bearer x"}]},
        \\  {"type":"sse","name":"old","url":"http://127.0.0.1:9/sse","headers":[]},
        \\  {"name":"","command":"x"},
        \\  {"name":"nocmd"},
        \\  {"type":"http","name":"nourl"},
        \\  "junk"
        \\]}
    , .{});
    const specs = try parse(a, params);
    try std.testing.expectEqual(@as(usize, 2), specs.len);

    try std.testing.expectEqualStrings("files", specs[0].name);
    try std.testing.expectEqualStrings("/usr/bin/files-mcp", specs[0].cfg.get("command").?.string);
    const argv = specs[0].cfg.get("args").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), argv.len); // the number is not an argument
    try std.testing.expectEqualStrings("--root", argv[0].string);
    try std.testing.expectEqualStrings("t", specs[0].cfg.get("env").?.object.get("TOKEN").?.string);
    try std.testing.expect(specs[0].cfg.get("url") == null);

    try std.testing.expectEqualStrings("browser", specs[1].name);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/mcp", specs[1].cfg.get("url").?.string);
    try std.testing.expectEqualStrings("Bearer x", specs[1].cfg.get("headers").?.object.get("Authorization").?.string);
    try std.testing.expect(specs[1].cfg.get("command") == null);
}
