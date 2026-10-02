"""Build the stale-triage history: a repo whose commit messages mention ENG keys.
Traps: a commit authored before the cutoff but committed after it, a longer key (ENG-1040),
a lowercase key (eng-105), and a key that appears only in a commit body."""
import os, subprocess
git = ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
subprocess.run(git + ["init", "-q", "-b", "main"], check=True)
with open(".git/info/exclude", "a") as f:
    f.write(".graff/\n.eval-*\n.pi/\n")
def commit(subject, adate, cdate=None, body=None, n=[0]):
    n[0] += 1
    with open("CHANGES.txt", "a") as f:
        f.write(f"{n[0]}: {subject}\n")
    env = dict(os.environ, GIT_AUTHOR_NAME="dev", GIT_AUTHOR_EMAIL="dev@example.com",
               GIT_COMMITTER_NAME="dev", GIT_COMMITTER_EMAIL="dev@example.com",
               GIT_AUTHOR_DATE=adate + " +0000", GIT_COMMITTER_DATE=(cdate or adate) + " +0000")
    subprocess.run(git + ["add", "-A"], check=True)
    msg = subject if body is None else subject + "\n\n" + body
    subprocess.run(git + ["commit", "-q", "-m", msg], env=env, check=True)
noise = ["Tidy imports", "Bump dependencies", "Refactor config loader", "Fix flaky clock test", "Rename helper",
         "Update README", "Lint fixes", "Speed up CI cache", "Drop dead code", "Log request ids"]
story = {
    2: ("ENG-106: board filter keeps assignee", None, None),
    4: ("Fix tax rounding (ENG-102)", None, None),
    6: ("ENG-101: first pass at session resume", None, None),
    9: ("ENG-104 retry 429s with backoff", None, None),
    12: ("ENG-104: honour Retry-After", "2026-08-13T09:00:00", None),
    15: ("Search index lag metrics (ENG-103)", None, None),
    18: ("ENG-105 strip EXIF on upload", None, None),
    21: ("ENG-105: strip GPS tags too", None, None),
    26: ("Digest dedupe", None, "Key digests on the message id; fixes ENG-108."),
    29: ("Follow-up on eng-105 review comments", None, None),
    31: ("ENG-107 keep UTF-8 in CSV export", None, None),
    35: ("ENG-101: resume keeps the session alive", None, None),
    38: ("ENG-103 shard rebuild", None, None),
    42: ("Migrate ENG-1040 tables", None, None),
    45: ("Link the ENG-1010 runbook", None, None),
}
# 48 commits, two per half-day from 2026-08-01 to 2026-08-20.
for i in range(48):
    day, half = 1 + i * 20 // 48, i % 2
    adate = f"2026-08-{day:02d}T{9 + 6 * half:02d}:{i % 60:02d}:00"
    if i in story:
        subject, cdate, body = story[i]
        commit(subject, adate, cdate, body)
    else:
        commit(noise[i % len(noise)], adate)
