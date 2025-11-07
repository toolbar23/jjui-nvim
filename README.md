# jjws.nvim

Neovim helpers for juggling multiple Jujutsu workspaces. The plugin keeps track of every workspace you care about, remembers your per-workspace editor state, and wraps an auxiliary “agent” terminal so you can bounce between branches without losing context.

## What It Does

- **Workspace discovery** – Lists JJ workspaces using `jj workspace list`, augmented with any entries you register manually. The picker groups workspaces by repo, highlights the active one, and lets you create or forget workspaces without dropping to a shell.
- **Persistent catalog** – Stores repo → workspace metadata in `~/.local/state/nvim/jjws_config.json`. The catalog persists across Neovim restarts, so the picker always knows your projects even if you are outside any JJ repo.
- **Session restore** – Saving a workspace captures:
  - Open file buffers (only on-disk files, no transient scratch buffers).
  - The focused buffer.
  - Whether the agent terminal is open and, if it is a Codex session, the session id.
  - Layout data lives under `~/.local/state/nvim/jjws_layout_<hash>.json`.
  When you switch back, buffers re-open and the agent terminal is resumed automatically.
- **Agent terminal** – Spawns your configured CLI helper (default `devagent`). Placement, size, and Codex session handling are configurable.
- **Diff helper** – Runs `jj diff -tool difftastic`, renders the ANSI output in a read-only scratch buffer, and lets you push inline comments to the agent window.

## Setup

With lazy.nvim (LazyVim et al.), import the bundled spec:

```lua
return {
  { import = "jjws.lazy" },
}
```

Override `opts` anywhere in your lazy config to tweak defaults, or skip the import and call `setup` manually:

```lua
require("jjws").setup({
  agent_cmd = { "bash", "-lc", "codex --repo $(pwd)" }, -- CLI to run in the agent terminal
  agent_size = 18,             -- split size (height for top/bottom, width for left/right)
  agent_position = "right",    -- "bottom", "top", "left", or "right"
  diff_command = { "bash", "-lc", "jj diff -tool difftastic --color=always" }, -- command used by :JJDiff
  diff_position = "right",      -- placement for the read-only diff window
  diff_comment_prefix = "[JJDiff]", -- prefix inserted in agent comments
  remember_last = true,        -- :JJResume jumps to the most recently used workspace per repo
})
```

Exported commands:

| Command        | Description |
| -------------- | ----------- |
| `:JJWorkspaces` | Toggle the workspace picker. `<CR>` switches, `r` registers the current default workspace, `w` creates a new JJ workspace, `x` forgets one. |
| `:JJUseWorkspace [name]` | Jump directly to a named workspace (falls back to picker). |
| `:JJResume`    | Reopen the last workspace you used in the current repo. |
| `:JJAgent`     | Open (or resume) the agent terminal for the active workspace. |
| `:JJDiff[!]`   | Run `jj diff -tool difftastic` and display the result in a read-only split. `!` keeps focus on the current window. |

> **Note**  
> The agent terminal only opens after you have explicitly selected a workspace in this Neovim session.

## Pick List Details

- Uses the JJ template `jj workspace list -T 'name ++ "\n"'` and normalizes paths based on the convention that workspace names match the directory name in the parent folder of the repo.
- Repo rows display a plain heading (no arrow); workspace rows show a `→` marker when they match the current Neovim working copy.
- The picker rebuilds after every action and keeps the selection on the item you just touched.
- Config storage keeps additional workspaces that might not exist on disk yet; you can register or remove them without leaving Neovim.

## Workspace Persistence

Every workspace switch triggers:

1. Save – record normal buffers, focused file, agent state, and Codex session id (if present).
2. Cleanup – wipe buffers, change directory, and create a fresh buffer.
3. Restore – reopen all saved buffers (respecting `primary` ordering) and relaunch the agent if it was running.

Files are only re-added if they still exist on disk. Non-file buffers (help, quickfix, scratch) are intentionally skipped to avoid various edge cases.

## Agent Behavior

- **Placement** – Controlled by `agent_position`. `"bottom"`/`"top"` use horizontal splits, `"left"`/`"right"` use vertical splits. `agent_size` is reused as the height or width depending on orientation (`agent_height` is still accepted for backward compatibility).
- **Codex session workaround** – When `agent_cmd` references `codex`, the plugin:
  1. Spawns a hidden `codex 'say ready'`.
  2. Waits until it prints `ready`, then SIGINTs it.
  3. Parses the “To continue this session, run `codex resume <uuid>`” line and stores the session id.
  4. Launches the visible terminal with `codex resume <uuid>`.
  5. Adds the session id to the per-workspace layout so a subsequent restore uses `codex resume …` automatically.
- If session creation fails (timeout or parsing error) a warning is shown and the configured command runs as-is.

## Diff Helper

- `:JJDiff` shells out to `jj diff -tool difftastic --color=always`, shows the colorised output in a scratch buffer, and by default moves focus to that split (add `!` to stay put).
- The diff buffer exposes `gr` to refresh and `gc` (normal/visual) to annotate a line or selection. Comments prompt for text, include the quoted hunk, and are relayed to the agent window.
- If the agent terminal is closed, the helper re-opens it automatically before sending the comment.

## State Files

- Persistent catalog: `~/.local/state/nvim/jjws_config.json`
- Layout snapshots: `~/.local/state/nvim/jjws_layout_<hash>.json`
- Last workspace per repo: `~/.local/state/nvim/jjws_last_<hash>.json`

Feel free to delete these if you want a fresh start—only runtime convenience is affected.

## Troubleshooting

- Run `:messages` if the picker flashes an error; all notifications are logged there.
- If Codex sessions fail to resume, ensure `codex` is available in `$PATH` and prints the standard resume line. You can also disable the special handling by swapping `agent_cmd` to a non-Codex command.
- When working outside a JJ repo the picker still opens but mutations (`r`, `w`, `x`, agent restore) are disabled until you select a workspace inside a repository.

## Roadmap / Ideas

- Optional persistence for additional buffer types (quickfix, terminals).
- Richer picker metadata (e.g., current branch, ahead/behind status).
- Tests around Codex session parsing for more resilient error handling.

For now the plugin favors practical helper workflows over polish; reports and patches welcome. 😊
