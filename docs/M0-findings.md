# M0 findings: PreToolUse hook behaviour

Verified with Claude Code 2.1.292 (`claude -p ... --output-format json`), default permission mode, macOS.
Each experiment ran in its own `/private/tmp/m0-<name>/` directory with a project-level `.claude/settings.json`
(matcher `Bash`, command hook pointing at a logging script). Evidence is in each directory:
`hook.log` (START/END timestamps), `stdin-<pid>.json`, `res.json`, `wall.txt`, `out.txt` (exists only if the tool ran).
Directory prefixes: `e*` first batch, `f*` second batch, `g*`, `h*`, `k*`, `p*`, `n*` follow-ups. Runner scripts: `/private/tmp/m0-lib/`.
Test command was `touch out.txt` (needs approval in default mode) or `echo hello-m0-marker` (auto-allowed read-only).

Limitation: all runs are non-interactive (`-p`), so a native prompt cannot be answered. "Falls back to native flow"
below means the outcome equals the run without a hook (tool denied for lack of approval, or auto-allowed if the command needs none).
Whether the interactive prompt then appears was not observed.

## Results

| # | Result | Evidence |
|---|---|---|
| E1 | Claude waits for the hook (5.0 s). Exit 0 with no output is "no decision": the tool then goes through the normal permission check. `touch` was denied for lack of approval, no `out.txt`. | `m0-e1/hook.log` 358.311 -> 363.342 |
| E2 | No `timeout` set, hook slept 100 s. The hook was NOT killed (ran 103.4 s, finished on its own). Exit 0 with no output then fell back to the native check (`touch` denied, not run). Default hard timeout is therefore above 103 s; its exact value was not found. | `m0-e2/hook.log` 353.335 -> 456.737 |
| E3 | `"timeout": 120`, hook slept 95 s: ran to completion (98.4 s), then native fallback as in E1. | `m0-e3/hook.log` |
| E3+ | Blocking 95 s works for real decisions too. With `allow` after 95 s the tool ran (`out.txt` exists), with `timeout` 120 (`h1`) and with no timeout (`h2`). With `deny` + reason after 95 s the tool was blocked and the model saw `late-deny-LD95` (`h3`). | `m0-h1`, `m0-h2`, `m0-h3` |
| E3++ | A configured timeout is enforced. `timeout: 10` with a 30 s hook: hook ended after 9.8 s. A timed-out hook is a non-blocking failure: `echo` ran, `touch` fell back to native denial. | `m0-f2c_echo`, `m0-f2c_touch` hook.log |
| E4 | Exit 2 + stderr: tool blocked (no `out.txt`). Transcript tool_result (is_error true): `PreToolUse:Bash hook error: [/private/tmp/m0-f4/hook.sh]: blocked-by-agentpanel-test-reason-XYZ123`. The model sees the stderr text, with that prefix. | `m0-f4/res.json` (stream-json) |
| E5 | stdout `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",...}}` + exit 0: `touch` ran (`out.txt` exists). The same command with a no-output hook (`e5ctl`) was denied for lack of approval. So `allow` skips the native approval. | `m0-e5`, `m0-e5ctl` |
| E6 | JSON `deny` + `permissionDecisionReason`: blocked, no `out.txt`. tool_result is exactly `denied-reason-ABC789` (is_error true), no prefix. | `m0-f6/res.json` |
| E7a | JSON `ask`: tool not run in `-p`. tool_result is the supplied reason (`ask-reason`). Also on `echo hello-m0-marker`, which runs without a hook, `ask` still forced the prompt (denied in `-p`, `m0-g1`). | `m0-f7a`, `m0-g1` |
| E7b | Empty output, exit 0: native flow. `touch` denied with Claude's own message ("needs approval ..."); `echo` ran normally (`m0-f5echo`, `m0-k3`). | `m0-e7b`, `m0-f5echo` |

Allow/deny rules vs. hook (`n1`-`n4`, run with `--allowedTools` / `--disallowedTools "Bash(echo hello-m0-marker)"`):
- Allow rule + hook `ask`: blocked (`ask-over-allow-N1`). The hook can force a prompt over an allow rule.
- Allow rule + hook `deny`: blocked (`deny-over-allow-N2`).
- Allow rule + empty hook: ran.
- Deny rule + hook `allow`: still denied ("Permission to use Bash ... has been denied."). A hook `allow` does not override a deny rule.

Setup note: `permissions.allow` in a project `settings.json` is ignored in `-p` mode until the workspace trust dialog is accepted
(CLI message seen in `m0-ctl`). The allow/deny-rule runs therefore used the `--allowedTools` / `--disallowedTools` flags (`n*`, `r*`; `r*` repeated `n*` with the same outcomes).

| # | Result | Evidence |
|---|---|---|
| E8 | Hooks DO overlap for read-only commands: three parallel `echo` calls started at 026.241, 026.241, 026.595 and ended at 034.729, 034.729, 035.079 (8 s hooks, ~9 s total). For three parallel `touch` calls (write commands, `e8`, `p1`) the hooks ran strictly one after another (each START after the previous END, ~8 s each). The two cases differ in command type as well as in prompt, so "writes are serialized by Claude Code" is the likely cause, not an isolated experiment. In the serialized case 3 hooks that each wait 90 s would take ~270 s in total. | `m0-p2`, `m0-f8` (overlap); `m0-e8`, `m0-p1` (serial) |
| E9a | Hook command path does not exist: no hook ran, no error visible to the model or in `res.json`/`err.txt`. `echo` ran; `touch` fell back to native denial. Non-blocking failure. | `m0-f9a`, `m0-e9a` |
| E9b | Hook SIGKILLs itself (START logged, no END): non-blocking. `echo` ran; `touch` fell back to native denial. (`f9b` took 70 s wall for unexplained reasons, the model-visible outcome was still normal.) | `m0-f9b`, `m0-e9b` |
| E9c | Hook exits 1 with stderr text: non-blocking, `echo` ran. Only exit 2 blocks. | `m0-f9c` |
| E10 | A command already allowed by a rule (`--allowedTools "Bash(touch out.txt)"`): hook is still called (hook.log present), and the tool ran with an empty hook. A hook `ask` or `deny` overrides the allow rule (blocked, hook reason shown). A hook `allow` does NOT override a deny rule (`--disallowedTools`): "Permission to use Bash with command ... has been denied." Precedence: deny rule > hook ask/deny > allow rule. | `m0-f10`, `m0-f10b`, `m0-n1`..`n4`, `m0-r1`..`r4` |
| E11 | stdin JSON field names and types below (values not recorded). | `m0-*/stdin-<pid>.json` |

E11 stdin fields (name: type): `session_id`: string (36 chars, UUID); `transcript_path`: string; `cwd`: string; `prompt_id`: string (UUID);
`permission_mode`: string (`default` seen); `effort`: object with `level`: string (`medium` seen); `hook_event_name`: string (`PreToolUse`);
`tool_name`: string (`Bash`); `tool_input`: object with `command`: string and `description`: string; `tool_use_id`: string.
All named fields in IMPLEMENTATION.md E11 are present. Extra fields: `prompt_id`, `permission_mode`, `effort`, `tool_use_id`, `tool_input.description`.

## Differences from IMPLEMENTATION.md assumptions

- Default hard timeout: not determined. A hook with no `timeout` survived 103 s, so it is above that, and 95 s blocking works with or without a configured timeout. Do not rely on the default; set `timeout` explicitly. Units are seconds (`timeout: 10` ended a 30 s hook after 9.8 s).
- `ask` is not a safe "no decision". It forces the permission prompt even for commands that are auto-allowed (`echo` denied in `-p`, `m0-g1`), and the model saw the ask reason as the tool result. Use empty output and exit 0.
- Exit 2 works, but the model sees `PreToolUse:Bash hook error: [<hook path>]: <stderr>`. JSON `deny` gives the bare reason with no prefix. Both block.
- A timed-out, crashed, missing or exit-1 hook never blocks: Claude falls back to its normal permission flow (fail-open to native flow).
- A hook `allow` cannot override a deny rule. A hook `ask`/`deny` can override an allow rule.
- Not observed: the interactive native prompt (all runs were `-p`), and whether a hook `allow` is honored identically in interactive mode.

## Exit decision

Outcome 1, proceed to M1 with the main plan. Evidence: a hook blocked for 95 s and then returned a real decision (`allow` ran the tool, `deny` blocked it with the reason shown to the model), both with `timeout: 120` and with no timeout set. Empty output with exit 0 falls back to the native permission flow.
Conditions: the installed hook entry must set `"timeout"` explicitly (suggest 120) so behavior does not depend on the unknown default; keep the app-side timer at 90 s; verify the interactive prompt manually once during M1/M7 since `-p` cannot show it; when the model issues several write commands in one turn, expect their hooks to run serially.

## WireDecision -> hook output (verified)

| WireDecision | stdout | stderr | exit | Verified outcome |
|---|---|---|---|---|
| `allow` | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"<text>"}}` | empty | 0 | Tool runs without native approval (E5, h1/h2). Does not override a deny rule. |
| `allow_similar` | same as `allow` (similarity rule storage is app-side; writing permission rules was not tested) | empty | 0 | as `allow` |
| `deny` | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"<reason>"}}` | empty | 0 | Tool blocked, model sees exactly `<reason>` (E6, h3). Alternative: stdout empty, stderr `<reason>`, exit 2: blocked, model sees `PreToolUse:Bash hook error: [path]: <reason>` (E4). |
| `no_decision` (and nil/timeout/error) | empty | empty | 0 | Native permission flow (E1, E7b, k3). Do not use `ask`. |

Change needed in `Sources/MusterProtocol/HookOutput.swift` (not edited here): `deny` should prefer the JSON form above with exit 0; the exit-2 form currently coded also works.
