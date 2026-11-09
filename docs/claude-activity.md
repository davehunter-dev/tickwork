# What Claude is doing, in the loop's log

**TLDR.** While a child runs, `tickwork loop` shows only Claude's reply text, so
a child reading files, running tests or waiting on a subagent looks idle. The
stream already carries every tool call, every failed tool result and every
subagent's tool calls and ending; Tickwork drops them. This design prints one
short line for each, in stream order, between the reply text it already shows.
Thinking can be shown too, as the summaries the API writes, with one more CLI
flag. Each line comes from one stream line, so the only new state is one flag
for "inside a thinking block". The decisions worth checking:
- **Thinking needs `--thinking-display summarized`, which `claude --help` doesn't
  list.** It is the only way found to get thinking text headlessly. If a release
  rejects it, the supervisor relaunches that child once without it, warns, and
  drops it for the rest of its run. See "If the flag is rejected".
- **Failures are shown and successful results are not.** A failed command or a
  denied permission is the result a person watching needs; anything else would be
  a dump.
- **Subagent text stays hidden.** Its tool calls and its ending are shown;
  its prose comes back to the parent anyway.

## What the stream carries

Measured on `claude` 2.1.316 with the child's flags (`-p --output-format
stream-json --verbose --include-partial-messages`), using a prompt that thinks,
runs Bash, reads a file, fails a command and starts a subagent.

| Line | Carries | Tickwork today |
|---|---|---|
| `stream_event` `text_delta`, top level | the reply, streamed | shown |
| `stream_event` `content_block_start` `tool_use` | the tool's name, before its input | the status block's current tool, once the pinned block lands |
| `stream_event` `input_json_delta` | the tool's input in fragments | dropped |
| `assistant`, `tool_use` block | name and complete input, once the input is written | dropped |
| `user`, `tool_result` block | the result, with `is_error: true` on a failure or a denied permission | dropped |
| `assistant` / `user` with `parent_tool_use_id` | a subagent's tool calls and results, whole, not streamed | dropped |
| `system` `task_started` | a subagent's or background task's description and type | dropped |
| `system` `task_progress` | its tool count, elapsed time and last tool | dropped |
| `system` `task_notification` | its ending: `status` and `usage` (`tool_uses`, `duration_ms`) | dropped |
| `stream_event` `thinking_delta` | thinking text: **empty by default**, the API's summary with `--thinking-display summarized` | dropped |
| `system` `thinking_tokens` | an estimate of thinking tokens so far, while thinking | dropped |
| `system` `status` | `requesting`, as each API request starts | dropped |
| `rate_limit_event`, `result` | usage windows; the ending | read by the supervisor |

**Not available headlessly:**
- **The model's raw reasoning.** Only the API's summary, and only with the flag
  above. The `showThinkingSummaries` setting, passed with `--settings`, did not
  change the stream in `-p`.
- **A running command's output.** A Bash call's output arrives whole in its
  result, so a ten-minute test run is one call line and then silence.
- **A subagent's text and thinking,** unless `--forward-subagent-text` is passed.
  Its tool calls are forwarded without it.

`--include-hook-events` adds hook lifecycle lines, and `--forward-subagent-text`
adds subagent prose. Neither is recommended: both are volume, not insight.

## What it prints

Each activity line is indented by its depth: two spaces for the top-level
session, four for a subagent's. On a terminal it is dim; otherwise it is the same
text, plain. A line too long is cut, ending in `…`. With the status block drawn it
is cut to the terminal's columns as measured when it is written. The plain log,
whether or not stdout is a terminal, has no size, so it cuts at
`activityLineWidth`, 160 characters: wide enough for a path and a description,
narrow enough that a pasted script can't fill a CI log.
- **A tool call,** from an `assistant` message's `tool_use` block:
  `<name>: <detail>`. The detail is the input's first string among
  `description`, `file_path`, `pattern`, `url`, `query`, `skill` and `command`,
  with newlines collapsed and the child's working directory removed from the
  front of a path. A tool with none of these prints its name alone. The complete
  message is used rather than the streamed fragments, so nothing is assembled.
- **A failed result,** from a `tool_result` with `is_error: true`:
  `failed: <content>`, one level deeper than calls at that depth. `content` is
  read as a string, or, when it is an array, as the `text` of each `text` block;
  other blocks are skipped. Its lines are joined by ` · `. A failure with no text
  prints `failed` alone.
- **A subagent's or background task's end,** from `task_notification`:
  `task <status> (<n> tools, <duration>)`, always at the top-level session's
  depth. `<n>` is `usage.tool_uses` and `<duration>` is `usage.duration_ms`
  in the supervisor's form (`6s`, `5m 21s`), from the same `duration(_:)`.
  A notification without `usage` prints `task <status>`.
- **Thinking,** from top-level `thinking_delta` text: streamed like the reply,
  dim, after a `thinking (summary):` lead, which says it is the API's summary and
  not the reasoning itself. The lead is why one flag is kept. An empty delta
  prints nothing, so without the flag thinking stays invisible as it is today.

The start of a subagent is its `Agent` tool line, so `task_started` adds nothing.
Successful results, `input_json_delta`, `task_progress`, `thinking_tokens` and
`status` print nothing. `--json` and the supervisor's own lines don't change. The
status block's current tool, from `content_block_start`, doesn't change either.

An example, as it reads without a terminal:

    12:00:41 🚀 example-org/a: launching Claude for an assignment
    thinking (summary): The assignment is an engineer start on #42, so I'll read the issue
    and every comment before touching code.
      Bash: Read the issue and its comments
    I'll take #42: the parser drops a trailing newline.
      Read: Sources/Parser.swift
      Agent: Find every caller of parse(_:)
        Grep: parse\(
        Read: Sources/Loader.swift
      task completed (2 tools, 6s)
      Edit: Sources/Parser.swift
      Bash: Run the tests
        failed: Exit code 1 · Parser.swift:41: error: expected ';'
    The test caught a missing semicolon; fixing it and running them again.
      Edit: Sources/Parser.swift
      Bash: Run the tests
    12:06:02 ✅ example-org/a: Claude finished (31 turns, 5m 21s)

## How

`claudeStream` in `LoopOutput.swift` becomes the parser for every line above,
with one new `ClaudeStream` case per kind of line. `SpawnedChild`'s reader
forwards them as it forwards text now, and `HumanOutput.claude` writes each under
its existing lock. An activity line ends any partial line first, as a supervisor
line does. In block mode it is committed to the log the way the reply's rows are.
The only added state is `HumanOutput`'s "inside thinking", set by the lead and
cleared at the block's end. It is touched only under that lock, on the child's
stdout reader thread.

Text in an `assistant` message is ignored, because its deltas have already been
shown.

## If the flag is rejected

`claude` rejects an option it doesn't know before it writes anything to stdout:
it exits 1 with one stderr line. Recorded on 2.1.316 with a misspelt name and
value, the two forms this flag can fail with are:

    error: unknown option '--thinking-display'
    error: option '--thinking-display <display>' argument 'summarized' is invalid. Allowed choices are …

- **Stderr is always piped.** Block mode dims it in the log as now. The plain log
  and `--json`, which inherit it today, get a pass-through that writes each line
  to the supervisor's stderr unchanged. `SpawnedChild` keeps the first line in
  `ChildExit.firstError`, under its lock, set on the stderr reader thread.
- **`rejectedThinkingFlag(_:)`** is true for a child that wasn't signalled,
  exited non-zero, kept no stream line, and whose `firstError` starts with
  `error: ` and contains `'--thinking-display`. Both lines above match. Any other
  startup error, and any child that wrote a stream line, doesn't.
- **The supervisor holds `thinkingSummaries`,** true at start and touched only on
  its own thread, in `step`. `ChildRequest` carries it, and
  `childCommand(repository:thinkingSummaries:)` adds the flag when it is true.
  In `childExited`, before classifying: when the request carried the flag and
  `rejectedThinkingFlag` holds, it sets `thinkingSummaries` false, emits
  `thinking-unavailable` with the stderr line as `detail`, and calls `launch`
  again with the same purpose and evidence. That exit writes no `child-exit`,
  and counts as no result, no progress and no pause. Every other ending is
  classified as today.
- **It retries once, by construction:** the relaunch has no flag, so its exit
  can't match.
- **The warning:** `⚠️ example-org/a: Claude rejected --thinking-display;
  thinking summaries are off until the loop restarts`. With `--json` it is the
  event line.

The flag stays off for the rest of the run rather than per child, or every child
would fail once and warn again. A restarted loop tries it again, at the cost of
one start that exits before any request.

## Tasks

1. **Tool, failure and task lines.** The parser cases, the lines, and the
   rendering in both modes, tested from stream lines recorded with the probe
   above. `docs/supervisor.md`'s "What it prints" and `CHANGELOG.md` say what
   changed.
2. **Thinking summaries and the fallback.** `--thinking-display summarized` in
   `childCommand`, the thinking lead and styling, and everything in "If the flag
   is rejected". Tested with: both recorded error lines relaunching once without
   the flag; an unrelated startup error, such as an unknown
   `--permission-prompts`, and a child that wrote a `result` both classified as
   today; and the plain log's stderr still reaching stderr. `docs/supervisor.md`
   lists `thinking-unavailable` among the `--json` events, and `CHANGELOG.md`
   says what changed. Builds on the first.

## Limitations

- **Parallel subagents interleave.** Their lines share a depth, and a task's
  ending doesn't name its description, so two at once can't be told apart. Naming
  them would mean keeping a map from tool use to description.
- **A long command is still silent** until its result, as above.
- **Paths outside the working directory stay absolute** and are cut at the width.
- **Failure lines show the tool's own error text,** cut to one line. That may
  include a path or a command's stderr, but never more than one line.
- **A rejection in another wording isn't caught.** A release that changes the
  message, or removes the flag some other way, fails as today: ambiguous, pausing
  the login. Matching anything looser would risk retrying a real failure.
- **Whether summaries change usage or latency** was not measured.
