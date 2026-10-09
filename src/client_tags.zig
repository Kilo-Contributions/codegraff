//! Who is calling the Codegraff gateway: graff's version, the device it runs
//! on and the app that launched it. Sent to the `codegraff` provider only, as
//! `User-Agent: graff/<version>`, `X-Codegraff-Device` and `X-Codegraff-App`,
//! so a request in the dashboard shows which build and machine sent it.
//!
//! The device defaults to the hostname. A launcher states its own:
//! `GRAFF_DEVICE_NAME` (the name it shows for this machine) and
//! `GRAFF_HOST_APP` (e.g. `harness/0.2.110`). `GRAFF_CLIENT_TAGS=off` sends
//! neither the device nor the app; the User-Agent stays.

const std = @import("std");
const kimi_identity = @import("kimi_identity.zig");

pub const user_agent = "graff/" ++ @import("build_options").version;

const max_len = 64;
var device_buf: [max_len]u8 = undefined;
var app_buf: [max_len]u8 = undefined;
var device_override: []const u8 = "";
var app: []const u8 = "";
var enabled = true;

/// Printable ASCII only, trimmed, capped at the buffer: header-safe.
fn clean(buf: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    for (raw) |c| {
        if (n == buf.len) break;
        const ch: u8 = if (c == '\t') ' ' else c;
        if (ch < 0x20 or ch > 0x7e) continue;
        buf[n] = ch;
        n += 1;
    }
    return std.mem.trim(u8, buf[0..n], " ");
}

/// Startup, from the environment knobs (session_settings.applyEnvKnobs).
pub fn applyEnv(device_name: ?[]const u8, host_app: ?[]const u8, tags: ?[]const u8) void {
    if (tags) |v| {
        enabled = !(std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "false"));
    }
    if (device_name) |v| device_override = clean(&device_buf, v);
    if (host_app) |v| app = clean(&app_buf, v);
}

fn device() []const u8 {
    if (device_override.len > 0) return device_override;
    kimi_identity.fillHostFields();
    const host = kimi_identity.device_name;
    return if (std.mem.eql(u8, host, "unknown")) "" else host[0..@min(host.len, max_len)];
}

/// The device and app headers, into `buf`; none when turned off or unknown.
pub fn headers(buf: []std.http.Header) []std.http.Header {
    var n: usize = 0;
    if (!enabled) return buf[0..0];
    const name = device();
    if (name.len > 0 and n < buf.len) {
        buf[n] = .{ .name = "X-Codegraff-Device", .value = name };
        n += 1;
    }
    if (app.len > 0 and n < buf.len) {
        buf[n] = .{ .name = "X-Codegraff-App", .value = app };
        n += 1;
    }
    return buf[0..n];
}

fn reset() void {
    device_override = "";
    app = "";
    enabled = true;
}

test "a launcher's device name and app ride the gateway headers" {
    defer reset();
    applyEnv("Work\tlaptop ", "harness/0.2.110", null);
    var buf: [4]std.http.Header = undefined;
    const h = headers(&buf);
    try std.testing.expectEqual(@as(usize, 2), h.len);
    try std.testing.expectEqualStrings("X-Codegraff-Device", h[0].name);
    try std.testing.expectEqualStrings("Work laptop", h[0].value);
    try std.testing.expectEqualStrings("X-Codegraff-App", h[1].name);
    try std.testing.expectEqualStrings("harness/0.2.110", h[1].value);
}

test "GRAFF_CLIENT_TAGS=off sends neither tag" {
    defer reset();
    applyEnv("Work laptop", "harness/0.2.110", "off");
    var buf: [4]std.http.Header = undefined;
    try std.testing.expectEqual(@as(usize, 0), headers(&buf).len);
}

test "the User-Agent is graff/<version>" {
    try std.testing.expect(std.mem.startsWith(u8, user_agent, "graff/"));
}

test "the codegraff gateway gets graff/<version> and the client tag headers" {
    const hh = @import("http_headers.zig");
    const Provider = @import("provider.zig").Provider;
    defer reset();
    applyEnv("Work laptop", "harness/0.2.110", null);
    const p: Provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "mimo-v2.6-pro", .context = 200_000 };
    switch (hh.userAgent(p)) {
        .override => |ua| try std.testing.expect(std.mem.startsWith(u8, ua, "graff/")),
        else => return error.TestUnexpectedResult,
    }
    var buf: [12]std.http.Header = undefined;
    const h = hh.providerHeaders(std.testing.io, p, "Bearer k", &buf);
    var got_device: ?[]const u8 = null;
    var got_app: ?[]const u8 = null;
    for (h) |hdr| {
        if (std.mem.eql(u8, hdr.name, "X-Codegraff-Device")) got_device = hdr.value;
        if (std.mem.eql(u8, hdr.name, "X-Codegraff-App")) got_app = hdr.value;
    }
    try std.testing.expectEqualStrings("Work laptop", got_device.?);
    try std.testing.expectEqualStrings("harness/0.2.110", got_app.?);
    // Other providers get neither.
    const other: Provider = .{ .id = "openai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6", .context = 200_000 };
    for (hh.providerHeaders(std.testing.io, other, "Bearer k", &buf)) |hdr|
        try std.testing.expect(!std.mem.startsWith(u8, hdr.name, "X-Codegraff"));
}
