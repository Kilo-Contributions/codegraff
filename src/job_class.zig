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
    var buf: [16 * 1024]u8 = undefined;
    var out: Surface = .{ .buf = &buf };
    out.scan(cmd);
    var segments = std.mem.tokenizeAny(u8, out.buf[0..out.len], ";&|\n");
    while (segments.next()) |segment| if (segmentPersistent(segment)) return true;
    return false;
}

/// The part of a command the shell runs as commands (#1361). Heredoc bodies
/// and quoted multi-word strings are inline scripts or prose, so a Python
/// batch whose lines mention `postgres` or `--watch` is not read as a server.
/// A shell's own `-c '…'` script is still shell and is scanned.
const Surface = struct {
    buf: []u8,
    len: usize = 0,

    fn put(s: *Surface, bytes: []const u8) void {
        const n = @min(bytes.len, s.buf.len - s.len);
        @memcpy(s.buf[s.len..][0..n], bytes[0..n]);
        s.len += n;
    }

    fn scan(s: *Surface, cmd: []const u8) void {
        var heredocs: [4][]const u8 = undefined;
        var pending: usize = 0;
        var i: usize = 0;
        while (i < cmd.len) {
            const c = cmd[i];
            if (c == '\\' and i + 1 < cmd.len) {
                s.put(cmd[i .. i + 2]);
                i += 2;
            } else if (c == '\n') {
                s.put("\n");
                i += 1;
                for (heredocs[0..pending]) |delim| i = skipHeredocBody(cmd, i, delim);
                pending = 0;
            } else if (c == '<' and std.mem.startsWith(u8, cmd[i..], "<<") and !std.mem.startsWith(u8, cmd[i..], "<<<")) {
                i += 2;
                if (i < cmd.len and cmd[i] == '-') i += 1;
                while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
                const start = i;
                while (i < cmd.len and std.mem.indexOfScalar(u8, " \t\n;&|<>()", cmd[i]) == null) i += 1;
                const delim = std.mem.trim(u8, cmd[start..i], "\"'\\");
                if (delim.len > 0 and pending < heredocs.len) {
                    heredocs[pending] = delim;
                    pending += 1;
                }
                s.put(" ");
            } else if (c == '\'' or c == '"') {
                var end = i + 1;
                while (end < cmd.len and cmd[end] != c) : (end += 1) {
                    if (c == '"' and cmd[end] == '\\') end += 1;
                }
                const body = cmd[i + 1 .. @min(end, cmd.len)];
                if (std.mem.indexOfAny(u8, body, ws) == null) {
                    s.put(body);
                } else if (s.afterShellDashC()) {
                    s.put("\n"); // the script's first word is a command
                    s.scan(body);
                } else {
                    s.put(" ");
                }
                i = end + 1;
            } else {
                s.put(cmd[i .. i + 1]);
                i += 1;
            }
        }
    }

    /// The text so far ends in `sh -c`, `bash -c`, `zsh -c` or `dash -c`.
    fn afterShellDashC(s: *const Surface) bool {
        var words = std.mem.splitBackwardsAny(u8, std.mem.trimEnd(u8, s.buf[0..s.len], ws), ws);
        const flag = words.next() orelse return false;
        if (!std.mem.eql(u8, flag, "-c")) return false;
        const program = std.fs.path.basename(words.next() orelse return false);
        for ([_][]const u8{ "sh", "bash", "zsh", "dash" }) |shell| if (std.mem.eql(u8, program, shell)) return true;
        return false;
    }
};

/// Index just past the heredoc body that starts at `i` and ends with a line
/// equal to `delim` (leading tabs allowed, as `<<-` strips them).
fn skipHeredocBody(cmd: []const u8, i: usize, delim: []const u8) usize {
    var at = i;
    while (at < cmd.len) {
        const eol = std.mem.indexOfScalarPos(u8, cmd, at, '\n') orelse cmd.len;
        const line = std.mem.trimStart(u8, std.mem.trimEnd(u8, cmd[at..eol], "\r"), "\t");
        at = @min(eol + 1, cmd.len);
        if (std.mem.eql(u8, line, delim)) return at;
    }
    return cmd.len;
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
        // #1537: `gh pr checks --watch` exits when the checks finish; it is a
        // finite wait like `gh run watch`, not a dev-server watcher.
        if (std.mem.eql(u8, word, "--watch") and !hasProgram(w[0..i], "gh")) return true;
        if (std.mem.eql(u8, word, "--serve")) return true;
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
        // #1537: gh's own --watch ends when the checks do.
        "gh pr checks 42 --watch",
        "gh pr checks --watch --fail-fast --interval 30",
        "vite build",
        "docker compose up -d",
        "docker compose logs web",
        "make -j8",
        "python -m pytest -x",
        "git log --follow src/main.zig | head",
        "tail -n 20 build.log",
        "grep -rn nginx deploy/",
        "echo postgres is up",
        // #1361: inline scripts and prose are not the command being run.
        "python3 - <<'PY'\nimport subprocess\npostgres = connect()\nair = 1\nsubprocess.run(['tsc', '--watch'])\nPY\necho done",
        "python3 -c \"import os\nollama = os.environ.get('X')\nprint('npm start')\"",
        "cat <<-EOF > notes.md\n\ttail -f app.log\n\tEOF",
        "git commit -m 'run npm run dev and tail -f logs'",
        "echo 'docker compose up'",
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
        "bash -c 'cd web && npm run dev'",
        "sh -c \"uvicorn app:app --port 8000\"",
        "npm run \"dev\"",
        "cat > run.sh <<'EOF'\necho hi\nEOF\nnpm run dev",
    }) |cmd| {
        if (!looksPersistent(cmd)) {
            std.debug.print("classified as finite: {s}\n", .{cmd});
            return error.TestUnexpectedResult;
        }
    }
}
