//! Whether a foreground command that outlived its wait is a server (#1324).
//!
//! A command auto-parked after the foreground wait used to become a
//! persistent job unconditionally, so `action=output wait_ms>0` on a
//! `cargo test` or `sleep 45` snapshotted at once instead of waiting for
//! exit. Only commands that look like they keep running on purpose (dev
//! servers, watchers, followed logs, foreground containers, tunnels) park as
//! persistent now; everything else stays a finite job (ADR 0010 waits).
//! The same rule applies to `run_in_background` (#1349): a backgrounded
//! `cargo test` stays awaitable; a backgrounded dev server is persistent.

const std = @import("std");

/// Programs that serve until stopped whatever their arguments.
const server_programs = [_][]const u8{
    "uvicorn",     "gunicorn",    "hypercorn",    "daphne",      "nodemon",
    "live-server", "http-server", "browser-sync", "ngrok",       "cloudflared",
    "caddy",       "nginx",       "redis-server", "mongod",      "postgres",
    "ollama",      "mailhog",     "localstack",   "json-server", "air",
};

/// Subcommands that run a server or watcher for tools that also do finite work.
const server_verbs = [_][2][]const u8{
    .{ "npm", "start" },            .{ "npm", "dev" },         .{ "npm", "serve" },
    .{ "yarn", "start" },           .{ "yarn", "dev" },        .{ "yarn", "serve" },
    .{ "pnpm", "start" },           .{ "pnpm", "dev" },        .{ "pnpm", "serve" },
    .{ "bun", "dev" },              .{ "bun", "start" },       .{ "next", "dev" },
    .{ "next", "start" },           .{ "vite", "dev" },        .{ "vite", "preview" },
    .{ "astro", "dev" },            .{ "nuxt", "dev" },        .{ "remix", "dev" },
    .{ "wrangler", "dev" },         .{ "vercel", "dev" },      .{ "netlify", "dev" },
    .{ "hugo", "server" },          .{ "jekyll", "serve" },    .{ "mkdocs", "serve" },
    .{ "flask", "run" },            .{ "rails", "s" },         .{ "rails", "server" },
    .{ "manage.py", "runserver" },  .{ "cargo", "watch" },     .{ "webpack", "serve" },
    .{ "storybook", "dev" },        .{ "firebase", "serve" },  .{ "supabase", "start" },
    .{ "kubectl", "port-forward" }, .{ "minikube", "tunnel" }, .{ "graff", "serve" },
    .{ "tailscale", "serve" },      .{ "deno", "serve" },
};

const ws = " \t\r\n";

/// True when `cmd` looks like it keeps running until stopped.
pub fn looksPersistent(cmd: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, cmd, ";&|\n");
    while (segments.next()) |segment| if (segmentPersistent(segment)) return true;
    return false;
}

fn segmentPersistent(segment: []const u8) bool {
    var words: [32][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, segment, ws);
    while (it.next()) |word| {
        if (n == words.len) break;
        words[n] = std.mem.trim(u8, word, "\"'()");
        n += 1;
    }
    const w = words[0..n];
    var command_pos = true;
    for (w, 0..) |word, i| {
        const at_command = command_pos;
        command_pos = std.mem.indexOfScalar(u8, word, '=') != null and at_command or isWrapper(word);
        if (std.mem.eql(u8, word, "--watch") or std.mem.eql(u8, word, "--serve")) return true;
        if (std.mem.eql(u8, word, "-f") or std.mem.eql(u8, word, "-F") or std.mem.eql(u8, word, "--follow")) {
            if (hasProgram(w[0..i], "tail") or hasProgram(w[0..i], "journalctl") or hasWord(w[0..i], "logs")) return true;
        }
        const base = std.fs.path.basename(word);
        if (at_command) for (server_programs) |p| if (std.mem.eql(u8, base, p)) return true;
        if (i > 0 and std.mem.eql(u8, w[i - 1], "-m")) for (server_programs) |p| if (std.mem.eql(u8, word, p)) return true;
        for (server_verbs) |v| if (std.mem.eql(u8, base, v[0]) and followedBy(w[i + 1 ..], v[1])) return true;
        if (std.mem.eql(u8, base, "vite") and (i + 1 == w.len or std.mem.startsWith(u8, w[i + 1], "-"))) return true;
        if (std.mem.eql(u8, word, "http.server")) return true;
        if (std.mem.eql(u8, base, "php") and i + 1 < w.len and std.mem.eql(u8, w[i + 1], "-S")) return true;
        if (std.mem.eql(u8, word, "up") and (hasProgram(w[0..i], "docker-compose") or hasWord(w[0..i], "compose")) and !hasWord(w[i + 1 ..], "-d") and !hasWord(w[i + 1 ..], "--detach")) return true;
    }
    return false;
}

/// `verb` appears among the next few words, skipping `run` and flags
/// (`npm run dev`, `pnpm --filter web dev`, `python manage.py runserver`).
fn followedBy(rest: []const []const u8, verb: []const u8) bool {
    for (rest[0..@min(rest.len, 4)]) |word| {
        if (std.mem.eql(u8, word, verb)) return true;
    }
    return false;
}

/// Words after which the next word is still the program being run.
fn isWrapper(word: []const u8) bool {
    for ([_][]const u8{ "sudo", "exec", "nohup", "time", "env", "npx", "bunx", "uvx", "command", "nice" }) |w|
        if (std.mem.eql(u8, word, w)) return true;
    return false;
}

fn hasWord(words: []const []const u8, word: []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn hasProgram(words: []const []const u8, program: []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, std.fs.path.basename(w), program)) return true;
    return false;
}

test "finite commands from the reports stay finite (#1324, #1325, #1331)" {
    for ([_][]const u8{
        "sleep 45",
        "cargo test --workspace 2>&1 | tee /tmp/t.log; status=${PIPESTATUS[0]}; tail -n 40 /tmp/t.log; exit $status",
        "zig build test",
        "npm test",
        "npm run build",
        "pnpm install",
        "gh run watch 123 --exit-status",
        "vite build",
        "docker compose up -d",
        "docker compose logs web",
        "make -j8",
        "python -m pytest -x",
        "git log --follow src/main.zig | head",
        "tail -n 20 build.log",
        "grep -rn nginx deploy/",
        "echo postgres is up",
    }) |cmd| {
        if (looksPersistent(cmd)) {
            std.debug.print("classified as persistent: {s}\n", .{cmd});
            return error.TestUnexpectedResult;
        }
    }
}

test "servers, watchers and followed logs park as persistent" {
    for ([_][]const u8{
        "npm run dev",
        "cd web && pnpm dev",
        "yarn start",
        "next dev --port 3777",
        "vite",
        "npx vite --host",
        "python -m http.server 8000",
        "python manage.py runserver",
        "uvicorn app:app --reload",
        "tail -f /var/log/app.log",
        "docker compose up",
        "docker compose logs -f web",
        "cargo watch -x test",
        "tsc --watch",
        "php -S localhost:8000",
        "flask run",
        "kubectl port-forward svc/api 8080:80",
        "graff serve",
        "PORT=3000 nohup uvicorn app:app",
        "python -m uvicorn app:app",
        "journalctl -u api -f",
    }) |cmd| {
        if (!looksPersistent(cmd)) {
            std.debug.print("classified as finite: {s}\n", .{cmd});
            return error.TestUnexpectedResult;
        }
    }
}
