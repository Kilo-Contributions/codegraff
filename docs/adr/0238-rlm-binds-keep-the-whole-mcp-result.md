# 0238. rlm binds keep the whole MCP result

Status: proposed 2026-10-02

## Context

ADR 0029 slims large MCP list results in `exec.zig`: rows keep only
`id`/`identifier`/`title`/`name`, and a comment list becomes
`{n, latest_author}`. ADR 0225 kept the full payload behind a handle for a
direct call, but an rlm host call still bound the plain cut, so a script
could never reach a dropped field. The rule told the model to call the tool
directly instead.

That cut fits a report of ids, titles and comment counts. Tasks that need
any other field, such as rolling issues up by priority or filtering them by
estimate, could not stay inside rlm. The model left the script, called the
tool directly, then paged the handle with `read_tool_result`, whose 16 KB
slices each end with a `[a..b of N bytes]` marker. Joining the slices
broke the JSON, and the model spent more calls repairing it. A harness
whose code mode hands the script the whole result finished the same tasks
in fewer calls.

Slimming exists to keep large payloads out of the conversation. A bind is
not in the conversation: only `print()` output is.

## Decision

- An MCP call from inside an rlm script (`ToolCtx.rlm_host`) binds the
  tool's whole result. `exec.zig` no longer slims it.
- `print()` still shows the slim view (`rlm.maybeSlim`). An `each()` bind,
  one whole result per item, prints each item's own cut, the view the
  per-item slim used to bind.
- `project(x, field)` reads any field of a row. Over an `each()` bind of
  comment lists, `n` and `latest_author` read the fold, so scripts written
  against the printed view keep working.
- `write_file("f.json", x)` saves the whole result for a shell script.
- Inside rlm, `read_tool_result("tr_N")` with no range binds the whole
  stored result (its one positional argument is the handle), and a direct
  call's slim marker says so, so a model that called the tool directly can
  still bring every field into a script.
- The slim rule on load results says so: in rlm a bind keeps every field.
- The `each()` "needs a JSON array" error echoes at most 200 bytes of its
  argument, so a whole result never lands in the conversation by mistake.

## Consequences

Binds hold more bytes in memory for the rest of the session. Nothing new
reaches the model unless a script prints it, and printing applies the same
cut as before. A direct call is unchanged: slimmed, with the full result
behind a handle. Revisit if a model starts printing whole binds that slim
cannot cut.
