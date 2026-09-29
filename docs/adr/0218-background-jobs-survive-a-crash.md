# 0218. Background jobs survive a crash and come back on resume

Status: accepted 2026-09-29

## Context

A finite command started with `run_in_background` wrote into pipes that
graff read. When graff died without running its defers (a SIGKILL, a panic,
or a closed terminal, since the TUI re-raises SIGHUP and SIGTERM with the
default action), those pipes closed with it. The job died of SIGPIPE on its
next write, or ran on with its output and exit status lost. The resumed
session still held the job id, and `bash_output` could only call it
"interrupted or unknown outcome".

The unreal-agent harness keeps each running command's output on disk and
re-attaches the command after a restart.

## Decision

- A finite root job started in the background writes its stdout and stderr
  to files (opened `O_APPEND`) in `.graff/job-output/<id>/`, not to pipes.
  `meta.json` beside them records the id, session, command, cwd, the
  leader's pid and start identity, and the owning graff's pid and start
  identity. The job's own shell writes an `exit` receipt from an EXIT trap.
  The trap runs in that same shell, not in a wrapper process, so `exec cmd`
  still makes `cmd` the group leader. The command runs under `eval` with no
  positional parameters and `$0` of `/bin/sh`, as under `sh -c`.
- While graff lives, a file pump (`job_durable.zig`) keeps the rules of the
  pipe pump: the 256 KB unread cap, the #199 idle clock, kill, and detach at
  session end. It polls every 10 ms, rising to 100 ms, and reaps its child
  with `waitpid`. Once its reader has caught up past 8 MB, it empties the
  file.
- `reported` is written when the exit reaches the model: through
  `bash_output`, through `bash_kill`, or when the completion notice is
  delivered. Reaping the job at session end removes the directory.
  A job kept past session end keeps its directory.
- Loading a session (`--resume`, `/resume`, ACP `session/load`) scans the
  current workspace's `.graff/job-output`. Captures from this session that
  are unreported and whose owning graff is gone go back into the job pool
  under their old ids (`job_recover.zig`). They are watched through the
  receipt and the leader's start identity (#413), never `waitpid`.
  - A job that ended while graff was down reports through the normal
    completion notice.
  - A job that is still running reports when it ends.
  - A job that is gone without a receipt reports "ended" with its output.

  `bash_output` and `bash_kill` reach these jobs again. A kill signals the
  group only while the leader still carries its recorded start identity.
- Captures from other sessions are left for their own resume. They are swept
  once a week old and over. A reported capture whose owner is gone is
  removed.
- Some jobs stay on pipes: foreground commands (including ones parked after
  the foreground wait, whose `cmd &` idioms depend on pipe EOF), servers,
  subagent jobs, runs with no session, and Windows.

## Consequences

- A crash no longer kills or loses a background job. With ADR 0215, a
  headless `--resume` waits for the re-attached jobs before it ends.
- Job output sits on disk under `.graff/`, which git ignores (#1273). While
  no graff is running, nothing trims it: a runaway job grows its file until
  a resume catches up.
- After a restart, the exit status comes only from the receipt. A command
  that `exec`s, or that replaces the EXIT trap, then reports "ended" without
  a code. While graff lives, `waitpid` still supplies its status.
- stdout and stderr interleave per poll tick, not per write.
- A notice that was delivered but not yet saved when graff dies is not
  repeated. After resume, `bash_output` still returns that result.
- Processes that a job leaves running in the background are not waited for.
  Pipes behaved the same way once such a process redirected its output.
- Follow-up: make a foreground command durable once it is parked.
