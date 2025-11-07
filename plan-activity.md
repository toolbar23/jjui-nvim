# Agent Window Activity Monitoring Plan


## Goals
- Detect when any `jjws_agent` terminal stops producing output for a configurable quiet period (default 2s).
- Notify the user (via `vim.notify`) exactly once per burst of activity when the quiet period elapses.
- Avoid resource leaks and gracefully handle agent splits being reopened, closed, or restarted.

## Current Hooks
 `open_agent` launches the terminal with `vim.fn.termopen` but does not currently pass callbacks.
- Agent buffers are marked with `vim.b[buf].jjws_agent = true` and have a stored job id (`jjws_agent_job`).
- Helpers like `find_agent_terminal` iterate over all buffers to locate active agent terminals.
- No existing mechanism tracks stdout/stderr events or job exit for agents.

## Monitoring Strategy
1. Attach `on_stdout`, `on_stderr`, and `on_exit` callbacks inside `vim.fn.termopen` when launching an agent.
2. Maintain an internal table, e.g. `agent_activity[job_id]`, containing:
   - `bufnr`
   - `timer` (`uv.new_timer` or `vim.defer_fn` wrapper)
   - `last_event` timestamp (via `vim.loop.hrtime` or `os.clock`)
   - `notified` boolean to ensure one notification per inactivity window.
3. When stdout/stderr fires:
   - Update `last_event`.
   - Reset/stop the timer if already running.
   - Start/restart timer to fire after the configured delay (default 2000 ms).
   - Clear `notified` so future inactivity can trigger another notification.
4. Timer callback checks whether current time − `last_event` ≥ delay; if so:
   - Emit `vim.notify` (level configurable, default `INFO`).
   - Mark `notified = true` to suppress repeated alerts until new output arrives.
5. On `on_exit`:
   - Stop and close the timer.
   - Optionally trigger an immediate “agent finished” notification if the job exited silently.
   - Remove table entry.
6. Add an autocmd (`BufWipeout`/`TermClose`) fallback that cleans up if the buffer disappears unexpectedly.

## Existing Agent Buffers
1. Agents opened before the plugin reloads lack callbacks; address by:
    1. Scanning `jjws_agent` buffers on setup and calling `vim.api.nvim_buf_attach` with an `on_lines` no-op but `on_detach` cleanup plus polling `vim.fn.jobwait`? (Risky.)
    2. Prefer reattaching by capturing `terminal_job_id` and using `vim.fn.chansend`? Not viable.
2. Accept minimal support: if callback cannot be injected retroactively, instruct users to reopen agents after enabling monitoring.
3. Document this limitation in README.

## Configuration
- Extend `cfg` with:
  - `agent_quiet_ms` (default `2000`).
  - `agent_notify_level` (default `vim.log.levels.INFO`).
  - `agent_notify_message` template, e.g. `"Agent quiet for {secs}s"`.
- Provide API (`M.configure`) to override values dynamically.

## Implementation Steps
1. Extend `cfg` defaults with new monitoring options.
2. Introduce `agent_activity` module-level table and helper functions:
   - `start_watch(job_id, bufnr)`
   - `record_event(job_id)`
   - `finish_watch(job_id, opts)` (handles exit/cleanup)
   - `stop_timer(entry)`
3. Modify `open_agent`:
   - Pass callbacks to `termopen`.
   - In `on_stdout`/`on_stderr`, call `record_event`.
   - In `on_exit`, call `finish_watch`.
   - Immediately call `start_watch` after `termopen` returns a job id.
4. Add `vim.api.nvim_create_autocmd("BufWipeout", ...)` watching `jjws_agent` buffers as a secondary cleanup trigger.
5. Optionally expose a `:JJWSAgentStatus` command or Lua function to display current timers for debugging.
6. Update README / help docs to describe the new feature and configuration.

## Notifications
- Include workspace context (repo/workspace name) if available via `active_workspace`.
- Message example: `"[jjws] agent idle (workspace foo/default)"`.
- Convert inactivity ms to seconds for readability.

## Testing / Validation
- Manual workflow:
  1. Open agent, ensure notification doesn’t fire while output continues.
  2. Run a command that ends quickly; verify 2s later notification appears once.
  3. Trigger new output after notification; ensure second quiet period notifies again.
  4. Close agent split; confirm timers stop (no errors).
- Optionally develop a lightweight unit test using plenary to simulate timers (if test infra exists).

## Open Questions
- Should notification occur only when job exits? (Current plan: silence-only detection.)
- Do we need per-agent suppression toggles or command to mute notifications?
- Should inactivity period be exponential/backoff if agent remains idle for a long time?
