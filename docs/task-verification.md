# Task procedures and verification

The native macOS workspace offers **작업 절차·검증** from the toolbar when a task or
session is selected, and from the task header above a terminal. The sheet keeps the task
and checkout it was opened for, even if the outline selection changes.

## Procedures

Choose an optional **bug fix**, **feature**, or **code review** preset when creating a task,
or apply one in the procedure tab of an existing task. Each preset starts with a goal,
completion criteria, and practical steps. Edit the goal, criteria, and notes, mark steps
you have checked, then save. Replacing an existing draft asks for confirmation.

These checkboxes record the user's progress. They do not run tests or change task status.
Copy handoff includes the current draft and the last reviewed verification state. Copying
does not send anything to an agent or execute terminal input. An existing task's procedure
is preserved when another session is opened.

## Verification commands

In the verification tab, expand the command editor. Add a Python (`python3 -m pytest`),
Swift (`swift test`), Node.js (`npm test`), or Rust (`cargo test`) starter, or enter a custom
command. These are editable starting points: Byori does not infer the project's test runner.

Commands are shared across the project's tasks. Each has a name, executable, arguments,
timeout of 1–1,800 seconds, and a required flag. Up to 12 commands can be saved. Enter one
argument per line; empty lines are omitted. Byori executes the saved executable and argument
array directly in the displayed checkout. Quotes, pipes and shell substitutions in arguments
are literal; select a shell explicitly only when the intended command needs one.

Saving a command does not run it. Press **실행** for a saved command; unsaved command edits
disable execution. **취소** stops the managed process group and saves a cancelled result.
One verification runs per checkout at a time. While it runs, Byori prevents removing its
task/project/checkout or switching that checkout's branch. Quitting cancels and drains running
verification before exiting. These commands may execute project code and can modify files,
just as they would when the user runs them in a terminal.

## What a passing result means

Each receipt stores the command as executed, resolved executable, exit code, timestamps,
bounded output, and source fingerprints before and after execution. Viewing or refreshing
the sheet captures the current fingerprint. The UI shows the check time; it is not a live
file watcher. Refresh after editing files.

A command's current state is **passed** only when its latest receipt has a successful exit,
the saved command still matches, and all three complete fingerprints match. The fingerprint
covers HEAD, the staged index, and contents/types of tracked and unignored files across
languages and file formats. Repeated edits to an already-dirty file invalidate old results.
Changes during a run, command edits, cancellation, timeout, or interrupted execution cannot
produce a current pass. No required commands means **not configured**, not passed.

Fingerprints are bounded to 20,000 files, 128 MiB total, 16 MiB per file, 256 KiB per Git
inventory response, and a 10-second scan budget. Links, submodules, unsupported files,
truncated/unreadable inventories, races and exceeded limits remain **unverified**. Ignored
files, external dependencies, toolchain versions, environment variables and remote services
are outside the fingerprint. A pass establishes the recorded checks against those observed
inputs; it does not prove all requirements are satisfied or automatically complete a task.

## Storage and recovery

- Project command profile: `~/.byori/verification-profiles/<project-id>.json`.
- Procedure: `~/.byori/tasks/<task-id>/workflow.json`.
- Verification receipts: `~/.byori/tasks/<task-id>/verification.json`.

The task keeps the latest 30 receipts, each with up to 64 KiB of output and an explicit
truncation flag. These are private local files, independent of ByoriDB availability. They
move with the task when it is archived. Raw output is not promoted into project memory;
use an explicit compact checkpoint when durable findings should be shared with agents.
An unfinished persisted run is shown as interrupted after relaunch, never as successful.

This release adds native task procedures and verification receipts. It does not add
automatic workflow agents, learned skills, or a global completion gate to the CLI/MCP.
