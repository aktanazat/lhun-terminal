---
name: lhun
description: Read when you run inside tmux on a machine a user watches from Lhûn on their iPad or iPhone, and want them to see a server, log, test run or second agent beside your session, or to send to, read, or wait on another tmux session.
---

# Lhûn

The user watches this machine's tmux sessions from Lhûn on their iPad or iPhone. Each session is a pill
in the strip at the top of the screen, and up to two sessions share the screen as cards. `lhun here`
prints your session, window, pane and folder.

## Putting work beside you

```sh
lhun open -- npm run dev               # a new session on the right half, the command typed into its shell
lhun open --below --dir ~/src/app      # a shell on the bottom half, in that folder
lhun open --name build-logs            # that session, or a new shell with that name
```

It prints the session's name and whether the user now sees it beside you. The keyboard stays with your
card, and the new card takes the place of any second card there, so open a session only when the user
should look at it now. When they aren't looking at your session, the new one still starts and waits in
the strip; say so instead of asking them to find it.

## Other sessions

- `lhun new NAME --dir DIR -- COMMAND` starts a session out of sight; `lhun open --name NAME` shows it later.
- `lhun ls` lists every session with its state, program and folder.
- `lhun capture NAME 80` prints its last 80 lines. Capture a session you did not start before you send to it.
- `lhun send NAME TEXT` types TEXT and presses Return.
- `lhun wait NAME 900` waits up to 900 s for its program to finish (exit 0), fail (1) or ask something
  (2), and exits 124 on time out. It needs the program to report its state, as omp, Claude Code, Codex
  and pi do through Lhûn's status tap; with nothing reporting it waits out its time.

Leave sessions you did not start running.

## What the user already sees

- Every session's program, folder and task show on its pill. Agents show working, done, or waiting on
  the user, from the program status protocol or their titles, and a chime sounds when one finishes.
  Do not print status banners for the user's benefit.
- A session you start appears in the strip within a second.
