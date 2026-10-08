//! #1556: a host switches models by respawning with an explicit `--model` and
//! reattaching the conversation with session/load. Startup seats plan logins
//! only for the providers that `--model` can observe, so the saved session's
//! own provider must have its plan seated when the restore needs it.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const provider_mod = @import("provider.zig");
const credential_store = @import("credential_store.zig");
const credential_failover = @import("credential_failover.zig");

const plan_record =
    \\{"email": "you@example.com", "issuer": "https://auth.openai.com", "subject": "user-1",
    \\ "client_id": "oaiapp_x", "ext_agent_host_id": "urn:uuid:1", "id_token": "a.b.c",
    \\ "access_token": "plan-tok-1556", "refresh_token": "ref-1", "token_type": "Bearer", "expires_in": 3600,
    \\ "expires_at": 4102444800, "earliest_refresh_at": 4102444000,
    \\ "scopes": ["chatgpt.tokens.use.direct", "email", "offline_access", "openid", "profile", "resource.invoke"],
    \\ "saved_at": "2026-09-30T00:00:00Z"}
;

test "#1556 session/load seats the saved provider's plan login a scoped launch skipped" {
    const session = @import("session.zig");
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();
    credential_failover.resetForTest();
    defer credential_failover.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buf[0..try tmp.dir.realPath(io, &home_buf)];
    try tmp.dir.createDir(io, ".graff", credential_store.private_dir);
    try tmp.dir.createDir(io, ".graff/credentials", credential_store.private_dir);
    try credential_store.replaceFile(io, tmp.dir, ".graff/credentials/chatgpt-new.json", plan_record, credential_store.private_file);
    try tmp.dir.createDirPath(io, ".graff/sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".graff/sessions/plan-1556.session.json",
        .data = "{\"provider\":\"chatgpt-new\",\"model\":\"gpt-6.1-sol\",\"messages\":[{\"role\":\"user\",\"content\":\"remember 1556\"}]}",
    });

    // What `--model <another provider's model>` leaves behind: only that
    // provider's credential is seated, and the saved provider's slot is empty.
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
        if (!std.mem.eql(u8, spec.id, "anthropic")) continue;
        value.* = "launch-key";
        source.* = .environment;
    }
    try std.testing.expect(keys.get("chatgpt-new") == null);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "sonnet"),
        .messages = .init(arena),
        .sub = false,
        .label = "root",
        .out = null,
        .home = home,
        // The stored-key fill is not under test (and would read the Keychain).
        .stored_keys_loaded = true,
    };
    try session.loadSession(&root, &keys, arena, "plan-1556");
    try std.testing.expectEqualStrings("chatgpt-new", root.provider.id);
    try std.testing.expectEqualStrings("plan-tok-1556", root.provider.api_key);
    try std.testing.expectEqual(provider_mod.Keys.CredentialSource.login, keys.sources[indexOf("chatgpt-new")]);
}

fn indexOf(id: []const u8) usize {
    for (provider_mod.provider_specs, 0..) |spec, i| if (std.mem.eql(u8, spec.id, id)) return i;
    unreachable;
}
