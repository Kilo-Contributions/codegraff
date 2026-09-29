# Notices

Standing notes for anyone building a client on graff: the desktop app,
[Harness](https://github.com/justrach/harness), and third-party ACP clients.

## Clients stay 1:1 with ACP

Session behavior must be 1:1 with ACP (`graff acp`). A new-chat folder rule, a
worktree handoff, or a session cwd that exists only in a client is not done — wire the same behavior through the ACP session in the same
change. The workspace the agent runs in is not chrome.
