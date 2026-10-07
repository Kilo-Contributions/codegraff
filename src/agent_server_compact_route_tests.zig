//! First-party OpenAI routes compact only into the provider's own encrypted
//! state, and a blob-anchored history is metered by what it costs, not by its
//! byte length. Split from agent_server_compact_tests.zig (600-line ceiling).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const asc = @import("agent_server_compact.zig");
const test_support = @import("agent_compact_test_support.zig");

fn testAgent(a: std.mem.Allocator, id: []const u8, model: []const u8, context: u64) Agent {
    var agent = test_support.subAgent(a, false);
    agent.provider = .{ .id = id, .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = model, .context = context };
    agent.gpa = a;
    agent.out = null;
    agent.label = "t";
    agent.goal_note_fp = 0;
    agent.history_rewrites = 0;
    agent.messages = std.json.Array.init(a);
    agent.compaction_window = .{};
    agent.call_kind = .root;
    agent.stream_quiet = true;
    agent.tracer = null;
    agent.compact_pin_degraded = false;
    agent.compact_stall = .{};
    agent.compact_transport_failures = 0;
    agent.compact_summary_failures = 0;
    agent.last_request_write_failed = false;
    agent.last_request_context_overflow = false;
    return agent;
}

test "serverOnly: every first-party OpenAI route, including the ChatGPT plan" {
    var p: Provider = .{ .id = "chatgpt-new", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-6.1-sol", .context = 270_000 };
    try std.testing.expect(asc.serverOnly(p));
    p.id = "codex";
    try std.testing.expect(asc.serverOnly(p));
    p.id = "openai";
    try std.testing.expect(asc.serverOnly(p));
    p.id = "codegraff";
    p.model = "gpt-6-astra";
    try std.testing.expect(asc.serverOnly(p));
    p.id = "xai"; // client summary still wins there
    try std.testing.expect(!asc.serverOnly(p));
    p.id = "kilo";
    try std.testing.expect(!asc.serverOnly(p));
    p.id = "codex";
    p.kind = .anthropic;
    try std.testing.expect(!asc.serverOnly(p));
    p.kind = .responses;
    asc.g_server_compact_override = false; // GRAFF_SERVER_COMPACT=0 opts back into the summary
    defer asc.g_server_compact_override = null;
    try std.testing.expect(!asc.serverOnly(p));
}

test "a 1.4 MB compaction blob does not hold a ChatGPT-plan session over the window" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, "chatgpt-new", "gpt-6.1-sol", 270_000);
    const state = try a.alloc(u8, 1_400_000);
    @memset(state, 'g');
    var blob: std.json.ObjectMap = .empty;
    try blob.put(a, "type", .{ .string = "compaction" });
    try blob.put(a, "encrypted_content", .{ .string = state });
    try agent.messages.append(.{ .object = blob });
    try agent.messages.append(try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"todo_read\",\"arguments\":\"{}\"}", .{}));
    try agent.messages.append(try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"[x] done\"}", .{}));
    // The server bills this window at ~79k; /4 over the blob read ~350k and
    // forced a compaction before every tool call.
    const local = agent.fullRequestEstimateTokens();
    try std.testing.expect(local < agent.provider.compactAt());
    @import("agent_context.zig").replaceContextTokens(&agent, 79_000);
    try std.testing.expect(agent.last_context_tokens < agent.provider.compactAt());
    // No network is wired: a forced pass here would fail and say so.
    var aw: Io.Writer.Allocating = .init(a);
    agent.out = &aw.writer;
    asc.autocompactIf(&agent, agent.effectiveContextTokens(), true);
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
    try std.testing.expectEqualStrings("", aw.written());
}

test "a failed first-party compaction never falls back to a client summary" {
    const io = std.testing.io;
    const Server = struct {
        fn run(io_: Io, server: *Io.net.Server, hits: *std.atomic.Value(u32)) void {
            while (true) {
                const conn = server.accept(io_) catch return;
                defer conn.close(io_);
                _ = hits.fetchAdd(1, .acq_rel);
                var rbuf: [8192]u8 = undefined;
                var reader = Io.net.Stream.Reader.init(conn, io_, &rbuf);
                var length: usize = 0;
                _ = (reader.interface.takeDelimiter('\n') catch return) orelse return;
                while (true) {
                    const header = (reader.interface.takeDelimiter('\n') catch return) orelse return;
                    if (std.mem.eql(u8, header, "\r")) break;
                    if (std.ascii.startsWithIgnoreCase(header, "content-length:"))
                        length = std.fmt.parseInt(usize, std.mem.trim(u8, header[15..], " \r"), 10) catch return;
                }
                _ = reader.interface.take(length) catch return;
                const payload = "{\"output\":[]}";
                var wbuf: [1024]u8 = undefined;
                var writer = Io.net.Stream.Writer.init(conn, io_, &wbuf);
                writer.interface.print("HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ payload.len, payload }) catch return;
                writer.interface.flush() catch {};
            }
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var addr = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var hits: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Server.run, .{ io, &server, &hits });
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var agent = testAgent(a, "openai", "gpt-6-astra", 100_000);
    agent.io = io;
    agent.client = &client;
    agent.provider.url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/responses", .{server.socket.address.getPort()});
    var aw: Io.Writer.Allocating = .init(a);
    agent.out = &aw.writer;
    const was_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = was_json;
    for (0..4) |_| try agent.messages.append(try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}", .{}));
    // No blob yet, so the old policy ran compact() — a client summary.
    agent.compactOrRecover(false);
    try std.testing.expectEqual(@as(u32, 1), hits.load(.acquire)); // the /responses/compact call only
    try std.testing.expectEqual(@as(usize, 4), agent.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "auto-compaction failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "falling back to local") == null);
}
