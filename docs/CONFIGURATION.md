# Configuration

This guide is for anyone who wants Minga to work their way: options, keys, themes, language tools, and how much the agent may do without asking. You will change settings in one file and reload them without leaving the editor.

Minga is configured with real Elixir code, but setting an option takes one line and no Elixir knowledge. If Elixir is new to you, the [Elixir lesson](https://mingacode.dev/learn/elixir) on the site translates settings from other editors. Your config file is `~/.config/minga/config.exs` (or `$XDG_CONFIG_HOME/minga/config.exs`). Press `SPC f p` to open it from inside the editor.

If the file doesn't exist, `SPC f p` creates it with a starter template.

## Quick start

```elixir
use Minga.Config

set :tab_width, 4
set :line_numbers, :relative
set :scroll_margin, 8
```

That's it. Save the file and press `SPC h r`. The status bar shows "Config reloaded". Buffers you open after the reload use the new options, and `:tab_width` and `:line_numbers` also change in buffers that are already open. Minga also reads the file every time it starts. [Config reload](#config-reload) lists the few changes that need a restart.

## Options

`set/2` configures global editor options. These are the supported options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:tab_width` | positive integer | `2` | Number of spaces per indent level |
| `:line_numbers` | `:hybrid`, `:absolute`, `:relative`, `:none` | `:hybrid` | Line number display style |
| `:autopair` | boolean | `true` | Auto-insert matching brackets and quotes |
| `:autopair_block` | boolean | `true` | Auto-insert language-aware block-closing keywords on Enter |
| `:scroll_margin` | non-negative integer | `5` | Lines to keep visible above/below cursor when scrolling |
| `:max_file_size` | positive integer | `10485760` | Maximum file size in bytes Minga will open. Larger files show a text-only "file too large" surface instead of loading a buffer; checked with a pre-read stat so the gap buffer and tree-sitter parser never touch the content. Default 10 MB. Raise it for the brave. |
| `:resident_store_max_lines` | non-negative integer | `65536` | Maximum number of laid-out rows that can stay loaded in each frontend for immediate scrolling. Continuations count as rows. Set to `0` to disable residence. See [Fast scrolling (residence)](#fast-scrolling-residence) below. |
| `:resident_store_max_bytes` | positive integer | `10485760` | Maximum buffer byte size that still gets full-document residence. Residence needs both this and `:resident_store_max_lines`; set `:resident_store_max_lines` to `0` to disable residence regardless of byte size. Default 10 MB. |
| `:theme` | theme name atom | `:catppuccin_frappe` | Color theme (see [Themes](#themes) below) |
| `:indent_with` | `:spaces` or `:tabs` | `:spaces` | Whether to indent with spaces or tab characters |
| `:trim_trailing_whitespace` | boolean | `false` | Strip trailing whitespace on save |
| `:insert_final_newline` | boolean | `false` | Ensure file ends with a newline on save |
| `:format_on_save` | boolean | `false` | Run the filetype's formatter before saving |
| `:auto_save_delay_ms` | non-negative integer | `1000` | Debounce before dirty file-backed buffers auto-save; `0` disables auto-save |
| `:formatter` | string or `nil` | `nil` | Override the default formatter command (see [Formatters](#formatters)) |
| `:title_format` | string | `"{filename} {dirty}({directory}) - Minga"` | Terminal window title format (see [Window Title](#window-title)) |
| `:recent_files_limit` | positive integer | `200` | Max recent files tracked per project |
| `:persist_recent_files` | boolean | `true` | Write recent file history to disk (see [Projects](PROJECTS.md)) |
| `:agent_model` | string or `nil` | `nil` | Default model intent; resolves to one exact executable route before activation (see [Agent model selection](AGENT-MODEL-SELECTION.md)) |
| `:agent_model_favorites` | list of strings | `[]` | Stable model-route IDs or named hosted `provider:model` IDs pinned to the top of the picker |
| `:agent_tool_approval` | `:destructive`, `:all`, `:none` | `:destructive` | When to prompt before executing agent tools |
| `:agent_destructive_tools` | list of strings | `["write_file", "edit_file", "delete_file", "shell", "git_stage", "git_commit", "rename"]` | Which tools are classified as destructive |
| `:agent_session_retention_days` | positive integer | `30` | Days to keep saved agent sessions before auto-pruning |
| `:agent_session_idle_timeout_ms` | non-negative integer | `14_400_000` | Milliseconds before an idle detached remote agent session is reclaimed; `0` disables idle reclamation |
| `:startup_view` | `:agent` or `:editor` | `:agent` | Which view to show on startup (see [Startup view](#startup-view) below) |
| `:agent_auto_context` | boolean | `true` | Load CLI file as agent preview context on startup |
| `:agent_mcp_servers` | list of maps | `[]` | MCP servers to launch for native agent sessions (see [MCP servers](MCP.md)) |
| `:whichkey_layout` | `:bottom` or `:float` | `:bottom` | Which-key popup display mode (see [Which-key popup](#which-key-popup) below) |
| `:font_family` | string | `"Menlo"` | Font family or name (see [Fonts](#fonts) below) |
| `:font_size` | positive integer | `13` | Font size in points (see [Fonts](#fonts) below) |
| `:font_weight` | weight atom | `:regular` | Font weight (see [Fonts](#fonts) below) |
| `:font_ligatures` | boolean | `true` | Enable programming ligatures (see [Fonts](#fonts) below) |
| `:cursor_animate` | boolean | `true` | Smoothly animate cursor movement in GUI frontends |
| `:terminal_features` | map of feature to `:on` or `:off` | `%{}` | Force a terminal feature on or off (see [Terminal features](#terminal-features) below) |
| `:log_level` | `:debug`, `:info`, `:warning`, `:error`, `:none` | `:info` | Global minimum log level (see [Logging](#logging) below) |
| `:log_level_render` | log level or `:default` | `:default` | Log level for the render pipeline |
| `:log_level_lsp` | log level or `:default` | `:default` | Log level for LSP client communication |
| `:log_level_agent` | log level or `:default` | `:default` | Log level for AI agent providers |
| `:log_level_editor` | log level or `:default` | `:default` | Log level for general editor operations |

```elixir
set :tab_width, 2
set :line_numbers, :hybrid
set :autopair, true
set :autopair_block, true
set :scroll_margin, 5
set :theme, :catppuccin_mocha
set :font_family, "JetBrains Mono"
set :font_size, 14
set :font_weight, :regular
set :font_ligatures, true
set :cursor_animate, false
```

Invalid values show a clear error. Setting `:tab_width` to `-1` tells you it must be a positive integer.

### Agent desktop notifications

Minga can tell you when a local agent needs tool approval, finishes its queued work, or encounters an error while you use another app. The first desktop alert asks for macOS permission. Alerts use the Minga icon and omit project names, commands, and conversation details. Clicking one brings the editor forward.

macOS controls whether a desktop alert is temporary or stays until you dismiss it. Set this under **System Settings → Notifications → Minga**. Dismissing a desktop alert does not approve or cancel a tool request. The approval stays in the conversation until it is resolved, and Minga then removes the corresponding desktop alert. Errors stay in the conversation even if the desktop alert disappears.

The terminal frontend rings the terminal bell and sends a desktop alert with the same fixed messages. On macOS it posts the alert through `osascript`. On Linux it uses `notify-send`, which the `libnotify` package provides, and any freedesktop notification server shows it: mako on Omarchy, GNOME Shell, KDE Plasma. Linux alerts need a graphical session, so over SSH or on a text console you get only the bell. Open the conversation to read the tool request, result, or error.

To get alerted only when an agent is blocked or fails:

```elixir
set :agent_notify_on, [:approval, :error]
```

Use `set :agent_notifications, false` to turn off agent alerts. `:agent_notify_debounce` sets the minimum interval in milliseconds between repeated completions or repeated failures from the same session (default `5000`). It does not delay approvals.

### Terminal features

In a terminal, Minga asks what the terminal can do and falls back quietly where it cannot. `:checkhealth terminal` lists what it found. Sometimes it is wrong: a new terminal draws curly underlines that Minga has not heard of, or a remote shell hides that the terminal has 24-bit colour. Then you say so yourself:

```elixir
set :terminal_features, %{styled_underlines: :on, underline_color: :on}
```

Three features can be forced `:on` or `:off`: `:true_color`, `:styled_underlines` and `:underline_color`. Those are the ones Minga decides how to draw. The others (the Kitty keyboard protocol, synchronized output, focus reporting) are turned on by the terminal, which answers for them reliably, so they cannot be forced. Any other name is an error, so a typo cannot look like a setting that does nothing. The option applies when Minga starts; after changing it, restart Minga and run `:checkhealth terminal` to see the feature listed as forced by you. The details are in [the terminal design notes](design/tui.md#terminal-capabilities).

## Modeline

The modeline is the one place Minga's state is always visible. It is built from named segments, so you can hide information, move it, or add your own project-specific status. The same segments drive the macOS status bar and the terminal modeline: both draw the words the editor sends, in the order it sends them.

By default it reads, left to right: the mode, needs-you (only when a task needs you), the file with a dot when unsaved, your position among Minga's changes, git, Minga's state in words, diagnostics or a persistent problem, then the filetype and position on the right. Every segment you can click does what its key does, and hovering it names the key (in the terminal, the echo line says it when your terminal reports pointer motion).

### Built-in segments

| Segment | Shows |
|---------|-------|
| `:mode` | Current editing mode, such as `NORMAL`, `INSERT`, or `VISUAL` |
| `:needs_you` | How many of Minga's tasks need you, only when one does. Click or `SPC a a` opens them. It is the only segment that says "needs you": the `:minga` segment then shows just its mark and "Minga", so without `:needs_you` only that mark says it |
| `:filename` | Buffer name, with a dot when unsaved. Click or `SPC ,` opens the switcher |
| `:change` | Your position among Minga's changes in this file ("change 1/2"), while the cursor is inside one |
| `:git` | Git branch and changed-line count ("main +11"). Click runs whatever `SPC g g` runs |
| `:minga` | Minga's state with its mark and words: "Minga here 2/3" while it works in the file you are in, "Minga editing retry.ex 2/3" while it works in another, otherwise the state's word ("Minga needs you"). Click or `SPC a v` opens the conversation. `:agent` is its old name and still works |
| `:background_agent` | Running background subagent count and active background task label |
| `:plan_limit` | Subscription plan usage for the active agent model, only at 80% or more of a limit window (`Claude 82% · 5h`) or once the limit is reached (`Claude limit · resets 3:40 PM`). Click it to choose another model. Hidden under normal usage and when the route reports no usage. |
| `:diagnostics` | Error and warning counts. Click or `SPC c x` opens the list |
| `:config` | A config that did not load, as a persistent problem ("config: defaults") until a reload succeeds. Click or `SPC f p` opens the config file |
| `:parser` | A failed tree-sitter parser, as a persistent problem, or a restart in progress |
| `:lsp` | A failed language server, as a persistent problem ("elixir_ls failed"). Nothing while servers are healthy |
| `:filetype` | Filetype label |
| `:position` | Cursor line and column, always as `240:31` |
| `:percent` | Cursor position as a file percentage (not shown by default) |
| `:indent` | Indentation style and width (not shown by default) |
| `:selection` | Reserved for visual selection details |

### Choosing segment order

Use `:modeline_left_segments` and `:modeline_right_segments` to choose which segments appear. Omitting a segment hides it. The list order is the render order for that side.

```elixir
set :modeline_left_segments, [
  :mode, :needs_you, :filename, :change, :git, :minga, :diagnostics, :config, :lsp, :parser,
  :background_agent, :plan_limit, :draft, :conflict, :merge_conflict
]
set :modeline_right_segments, [:filetype, :position]
```

Move any built-in segment by putting it on the other side:

```elixir
# Put cursor position beside the filename and show indentation on the right.
set :modeline_left_segments, [:mode, :needs_you, :filename, :position, :git, :minga, :diagnostics]
set :modeline_right_segments, [:indent, :filetype]
```

### Agent status command

Set `:agent_status_command` to add stdout from a shell command to the `:minga` segment, after Minga's state ("Minga working sonnet | 42k"). The state word always stays, so the modeline never disagrees with the rest of the screen; while Minga has no state the command's text stands alone. Minga reruns it every `:agent_status_interval_ms` milliseconds, default `5000`; values below `1000` are treated as `1000`. Failed commands or empty output fall back to the built-in words and log one `*Messages*` entry.

```elixir
set :agent_status_command, ~s(echo "$MINGA_MODEL | $MINGA_STATUS")
set :agent_status_interval_ms, 5_000
```

Available environment variables: `MINGA_SESSION_ID`, `MINGA_MODEL`, `MINGA_STATUS`, and `MINGA_WORKDIR`. The command runs in the project Minga has open, and `MINGA_WORKDIR` names it; with no project open, both are the directory Minga was launched from.

### Separator style

`:modeline_separator` controls the glyph inserted between adjacent color zones.

| Style | Example |
|-------|---------|
| `:powerline` | Theme color transition, matching the historical Minga modeline |
| `:round` | `NORMAL file.ex` |
| `:slant` | `NORMAL file.ex` |
| `:none` | `NORMAL file.ex` |

```elixir
set :modeline_separator, :round
```

### Custom segments in `config.exs`

`modeline_segment/3` registers a segment from your config file. The block receives `ctx`, a map with the current modeline data and theme colors. Return one segment tuple, a list of segment tuples, `nil`, or `[]`. A segment tuple is `{text, fg, bg, opts, click_target}`.

```elixir
modeline_segment :word_count, side: :right, priority: 50 do
  if ctx.data.filetype in [:markdown, :text, :org] do
    words =
      case Minga.API.content() do
        {:ok, text} -> text |> String.split() |> length()
        {:error, :no_buffer} -> 0
      end

    {" #{words}W ", ctx.info_fg, ctx.bar_bg, [], nil}
  end
end
```

The `side:` option is the default side when you do not list the segment explicitly. It must be `:left` or `:right`, and `priority:` must be an integer. Invalid declarations fail during config load so you see the mistake immediately. Custom segment names cannot reuse built-in names like `:mode`, `:filename`, or `:git`, because built-ins always win during rendering.

Segment text and click command names are bounded to the GUI protocol's 16-bit string and section limits. Oversized strings or a status-bar payload that exceeds its wire-format limit are rejected before the frontend Port write; Minga does not truncate strings or drop trailing segments to make a payload fit.

You can still place the segment yourself:

```elixir
set :modeline_right_segments, [:word_count, :filetype, :position]
```

### Custom segments in extensions

Extensions use the same DSL inside a `use Minga.Extension` module. Segment names must be unique across config and loaded extensions; Minga rejects a duplicate rather than letting one source silently overwrite another.


```elixir
defmodule MyModeline do
  use Minga.Extension

  modeline_segment :project_name, side: :left, priority: 70 do
    {" my-app ", ctx.info_fg, ctx.bar_bg, [], nil}
  end

  @impl true
  def name, do: :my_modeline

  @impl true
  def description, do: "Project modeline segments"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config), do: {:ok, %{}}
end
```

Extension segments are removed automatically when the owning extension stops or reloads.

### Responsive truncation

When the window is too narrow, segments give way in a fixed order: first custom and optional segments (background agents, plan limit, indentation and so on), then the filetype, the position and git, then Minga's words shrink to its state mark and step count ("2/3"), then warnings. Mode, needs-you, the file name, change position, errors and persistent problems never drop. Each frontend measures its own width and applies this order, so narrowing changes presentation only and every key keeps its meaning. A custom segment's `priority:` does not change when it gives way.

## Agent model routes

Set `:agent_model` to a provider/model intent such as `"anthropic:claude-sonnet-4-20250514"`. Minga resolves it to one exact executable route before use. Open `/model` to inspect the protocol, endpoint, credential profile, limits, reasoning controls, and tool/image/streaming capability evidence for every available route.

Minga supports named hosted providers from its pinned catalog and `apple:system` on eligible Macs with the bundled inference helper. Custom local servers, endpoints, and provider endpoint overrides are not configurable. Minga rejects unavailable routes instead of silently falling back. See [Agent model selection](AGENT-MODEL-SELECTION.md) for runtime requirements and the model's compact tool set.

Extensions can add their own model routes, such as a subscription bridge or a company proxy. Their models appear in `/model` with the route's own readiness text, and they are reached as `"<route_id>:<model_id>"`. See [Model routes](EXTENSION_API.md#model-routes).

### Route credentials

Some routes need configuration you would rather not put in `config.exs`, such as a proxy token. Put it in `~/.config/minga/credentials.json` under `routes.<route_id>.env`:

```json
{
  "routes": {
    "company_proxy": {
      "env": {
        "COMPANY_PROXY_TOKEN": "replace-me",
        "COMPANY_PROXY_REGION": ""
      }
    }
  }
}
```

Minga passes this map only to that route's requests and availability checks, and never interprets it. An empty value means "unset". Values never appear in logs, `*Messages*`, session exports, or error text. `HOME`, `CLAUDE_CONFIG_DIR`, and `USERPROFILE` are rejected, so a route entry cannot point Minga at another tool's login. A route that signs in through its own tool keeps that login itself; Minga never reads or copies it.

## Agent reactive diagnostics

Minga can post a quiet agent-chat suggestion when saving a file introduces a new LSP error. This is off by default so the editor never talks over you unless you ask it to.

```elixir
set :agent_react_to_lsp_errors_on_save, true
```

When enabled, the agent chat gets the file, position, and diagnostic message. The suggestion stays in chat, so you can ask the agent to apply a fix, open chat to discuss it, or ignore the message to dismiss it.

## Agent tool approval

When the AI agent wants to run a destructive tool (writing a file, editing a file, or running a shell command), Minga pauses and shows a confirmation prompt:

```
⚠ Execute shell: mix test?  [y]es  [a]ll for session  [t]his turn  [n]o
```

- **y** or **Enter** approves the tool once.
- **a** trusts this tool for the rest of the session.
- **t** trusts this tool for the current turn.
- **n** rejects the tool. The agent gets "Tool rejected by user" as the result and continues its turn.

The approval mode resets at the start of each new agent turn. Session trust stays active until you revoke it or end the session. Turn trust clears when the current turn finishes.

Use `/trust list` to inspect trusted tools, `/trust revoke <tool>` to remove one, and `/trust clear` to remove all trusted tools.

### Controlling when approval is required

The `:agent_tool_approval` option controls the gate. Set it to `:destructive` to prompt only for destructive tools, `:all` to prompt for every tool call, or `:none` to auto-approve everything:

```elixir
# Default: prompt only for destructive tools
set :agent_tool_approval, :destructive

# Prompt for every tool call (read_file, list_directory, etc.)
set :agent_tool_approval, :all

# Auto-approve everything, never prompt
set :agent_tool_approval, :none
```

### Customizing the destructive tools list

The `:agent_destructive_tools` option controls which tools are classified as destructive. Only tools in this list trigger the approval prompt when `agent_tool_approval` is `:destructive`.

```elixir
# Default
set :agent_destructive_tools, ["write_file", "edit_file", "delete_file", "shell", "git_stage", "git_commit", "rename"]

# Trust file edits, only prompt for shell commands
set :agent_destructive_tools, ["shell"]

# Add a custom tool to the list
set :agent_destructive_tools, ["write_file", "edit_file", "delete_file", "shell", "git_stage", "git_commit", "rename", "deploy"]

# Empty list with :destructive mode = no prompts for built-in tools
set :agent_destructive_tools, []
```

The two options are orthogonal. `:agent_tool_approval` controls *whether* to prompt. `:agent_destructive_tools` controls *which tools* count as destructive when the mode is `:destructive`.

For the full option API, see `Minga.Config.Options`.

### Buffer-aware agent options

When agent tools are [routed through `Buffer`](BUFFER-AWARE-AGENTS.md), file-backed buffers auto-save after `:auto_save_delay_ms` so agent edits are not stranded only in memory. Set it to `0` if you want every dirty buffer to wait for an explicit save.

### What a crash can lose

Two things keep unsaved text safe, and `:auto_save_delay_ms` decides which one is at work:

| Setting | What protects your text | What a crash, a `kill` or a power cut can lose |
|---------|-------------------------|------------------------------------------------|
| Auto-save on (the default, `1000`) | The file itself: it is written 1 second after you stop typing | What you typed since your last pause of 1 second |
| Auto-save off (`0`) | A swap file: it is written 5 seconds after you stop typing | What you typed since your last pause of 5 seconds |

Both timers start again with every edit, so text typed without a pause that long is in memory only. With auto-save on, a swap file appears only when a save cannot finish (a read-only file, a full disk, a save conflict): the buffer stays unsaved, and after 5 seconds the swap file takes over.

After a crash, opening the same project gives the text back: the session is restored, each file with a swap file shows its unsaved text, and one notice says so. A buffer that crashes on its own, while the editor keeps running, loses nothing: it writes its text as it stops, and the editor reopens the file with it. Text that belongs to another project stays where it is until you open that project, and `SPC q u` lists everything that is waiting so you can recover or discard it. Quitting, with or without saving, removes this run's swap files. See [Unsaved text across a crash](ARCHITECTURE.md#unsaved-text-across-a-crash) for the full rules.

Some buffer-aware controls are still planned:

- Whether buffer forks merge automatically (clean merges only) or always go through diff review
- Whether to flush dirty buffers before agent shell commands

See [BUFFER-AWARE-AGENTS.md](BUFFER-AWARE-AGENTS.md) for the design.

## LSP settings

Some language servers ask the editor for project settings with `workspace/configuration`. Use `lsp_settings/2` when you want Minga to answer those requests for a server.

The first argument is the server name from the language definition. The second argument is the settings map that server expects. Minga deep-merges your settings with built-in language defaults, and your config wins when both define the same key.

```elixir
# Disable rust-analyzer's all-features cargo check default
lsp_settings :rust_analyzer, %{
  "rust-analyzer" => %{
    "cargo" => %{"allFeatures" => false}
  }
}

# Disable TypeScript formatting through typescript-language-server
lsp_settings :typescript_language_server, %{
  "typescript" => %{
    "format" => %{"enable" => false}
  }
}
```

Use string keys when the LSP section contains punctuation, such as `"rust-analyzer"`. Atom keys are converted to strings, which works well for simple nested keys like `format` and `enable`.

## Startup view

Minga boots into the full-screen agentic view by default. The chat panel is visible, the input is focused, and an agent session starts automatically. You're ready to talk to the agent the moment Minga opens.

If you pass a file on the command line (`minga foo.ex`), the file opens in the preview pane so the agent has context about what you're working on.

### Switching to editor-first startup

If you prefer the traditional file editing experience on startup, set `:startup_view` to `:editor`:

```elixir
set :startup_view, :editor
```

This restores the pre-1.0 behavior: Minga opens with a file buffer (or scratch buffer) and the agentic view is a toggle away via `SPC a a`.

### Controlling auto-context

When the agentic view is the startup view and you open a file from the CLI, the file's content is loaded into the preview pane by default. This makes the interaction feel like "I'm chatting about this file" rather than "I opened a file and there's a chat panel."

To disable this and start with a blank agentic view even when a file is provided:

```elixir
set :agent_auto_context, false
```

The file is still opened in a buffer (accessible via `SPC b b`), it just isn't surfaced in the preview pane automatically.

### CLI flag overrides

CLI flags override config options for a single invocation:

```bash
# Force editor mode regardless of config
minga --editor foo.ex

# Agentic view but don't load the file as context
minga --no-context foo.ex

# Editor mode with no file (scratch buffer)
minga --editor
```

### Summary of combinations

| Config | CLI | Result |
|--------|-----|--------|
| `startup_view: :agent` (default) | `minga` | Agentic view, empty |
| `startup_view: :agent` (default) | `minga foo.ex` | Agentic view, file in preview |
| `startup_view: :agent`, `agent_auto_context: false` | `minga foo.ex` | Agentic view, preview empty, file in buffer list |
| `startup_view: :agent` | `minga --no-context foo.ex` | Same as above |
| `startup_view: :agent` | `minga --editor foo.ex` | Editor view, file open |
| `startup_view: :editor` | `minga foo.ex` | Editor view, file open |
| `startup_view: :editor` | `minga` | Editor view, scratch buffer |

## Which-key popup

When you press a leader key (like `SPC`) and pause, a which-key popup appears showing all available continuations. By default it renders as a horizontal bar anchored to the bottom of the viewport (like Doom Emacs):

```elixir
set :whichkey_layout, :bottom   # default
```

Set it to `:float` to render the which-key popup as a centered floating window with a rounded border and title:

```elixir
set :whichkey_layout, :float
```

The float layout uses the same `FloatingWindow` primitive as the centered picker. It auto-sizes to fit the bindings (up to 70% width and 60% height of the viewport) and uses your theme's popup colors for the background, text, and border.

Both layouts respond to mouse clicks. In float mode, clicking outside the popup dismisses it.

## Themes

Minga ships 7 built-in color themes. Set one in your config and restart, or browse them live with `SPC h t`.

```elixir
set :theme, :catppuccin_mocha
```

| Theme | Style |
|-------|-------|
| `:astrodark` | Dark, AstroNvim |
| `:doom_one` | Dark, Doom Emacs |
| `:catppuccin_frappe` | Dark (default), Catppuccin family |
| `:catppuccin_latte` | Light, Catppuccin family |
| `:catppuccin_macchiato` | Dark, Catppuccin family |
| `:catppuccin_mocha` | Dark, Catppuccin family |
| `:one_dark` | Dark, Atom |
| `:one_light` | Light, Atom |

The theme picker (`SPC h t`) live-previews each theme as you navigate the list. Selecting one applies it for the current session. To make it permanent, add the `set :theme` line to your config file.

For theme internals, see `MingaEditor.UI.Theme`.

## Fonts

Font settings only apply to the GUI backend. **In TUI mode (the default), your terminal controls the font.** Change your font in your terminal emulator's preferences (Ghostty, Kitty, iTerm2, WezTerm, etc.) instead. The font options are accepted in TUI mode without error, they just have no effect.

```elixir
set :font_family, "JetBrains Mono"
set :font_size, 14
set :font_weight, :light
set :font_ligatures, true
```

### Font weight

Available weights: `:thin`, `:light`, `:regular`, `:medium`, `:semibold`, `:bold`, `:heavy`, `:black`. The default is `:regular`.

```elixir
set :font_weight, :light    # thinner strokes, popular for high-DPI
set :font_weight, :regular  # default
set :font_weight, :medium   # slightly heavier than regular
```

Not every font ships every weight. If the requested weight isn't available, macOS picks the closest match. Bold text from syntax highlighting still resolves to the font's bold variant regardless of this setting.

You can use any of these name formats:

- **Family name**: `"Fira Code"`, `"JetBrains Mono"`, `"Menlo"`
- **PostScript name**: `"FiraCode-Regular"`, `"JetBrainsMonoNF-Regular"`

If the font isn't found, Minga falls back to the system monospace font and logs a warning to `*Messages*`. The default is `"Menlo"` at size 13, which ships with every Mac.

### Programming ligatures

Programming ligatures combine multi-character sequences like `->`, `!=`, `=>`, `<=`, `::` into single visual glyphs. They're enabled by default:

```elixir
set :font_ligatures, true   # default
set :font_ligatures, false  # render each character individually
```

Ligatures only work when two conditions are met:
1. `:font_ligatures` is `true`
2. The font has ligature tables (Fira Code, JetBrains Mono, Cascadia Code, etc.)

Fonts without ligature tables (like Menlo or SF Mono) are unaffected by this setting. Setting `:font_ligatures` to `false` is useful if you're using a ligature font but prefer to see individual characters.

## Logging

Minga logs to `*Messages*` (viewable with `SPC b m`) and to `~/.local/share/minga/minga.log`. By default, the log level is `:info`, which suppresses noisy debug output like render pipeline timing.

```elixir
# Set the global floor (suppresses :debug by default)
set :log_level, :info
```

Each subsystem has its own log level override. Set a subsystem to `:debug` to see its detailed output without turning on debug logs everywhere:

```elixir
# Debug just the render pipeline
set :log_level_render, :debug

# Debug LSP communication
set :log_level_lsp, :debug
```

The subsystem options default to `:default`, which means "inherit from `:log_level`." You can also set a subsystem to `:none` to silence it completely, even for warnings and errors.

On macOS, frontend diagnostics appear under **GUI** in the Messages pane. To see debug entries, set `:log_level_port` to `:debug`, then turn on the Debug filter in the pane. If the editor core cannot connect, use Console or `log stream --level debug --predicate 'subsystem == "com.minga.editor"'`. Console separates native diagnostics by category, such as `Startup` and `BEAMProcess`.

### Subsystems

| Subsystem | Option | What it covers |
|-----------|--------|----------------|
| render | `:log_level_render` | Render pipeline stage timing and frame composition |
| lsp | `:log_level_lsp` | LSP server communication, requests, and errors |
| agent | `:log_level_agent` | AI agent providers, sessions, and tool execution |
| editor | `:log_level_editor` | General editor operations, commands, and file I/O |
| port / GUI | `:log_level_port` | Frontend and parser port diagnostics, including native macOS startup and recovery |

### Example: debugging a rendering issue

```elixir
set :log_level, :warning         # quiet everything else
set :log_level_render, :debug    # but show render pipeline details
```

Open `*Messages*` with `SPC b m` to see the per-stage timing output in real time.

## Window title

Minga updates the terminal window title to reflect the active buffer, just like Neovim and Doom Emacs. The default format is `{filename} {dirty}({directory}) - Minga`, which produces titles like `editor.ex (lib) - Minga` or `editor.ex [+] (lib) - Minga` for modified files.

Customize it with `:title_format`:

```elixir
# Just the filename
set :title_format, "{filename} - Minga"

# Include the mode
set :title_format, "{filename} {dirty}[{mode}] - Minga"

# Full path, no branding
set :title_format, "{filepath}"
```

Available placeholders:

| Placeholder | Expands to |
|-------------|------------|
| `{filename}` | File basename (e.g. `editor.ex`) |
| `{filepath}` | Full file path |
| `{directory}` | Parent directory name |
| `{dirty}` | `[+] ` if modified, empty otherwise |
| `{readonly}` | `[-] ` if read-only, empty otherwise |
| `{mode}` | Current mode in uppercase (e.g. `NORMAL`, `INSERT`) |
| `{bufname}` | Buffer display name (filename, or `*scratch*` for unnamed buffers) |

The title is restored to its previous value when Minga exits.

## Fast scrolling (residence)

Minga keeps the whole document resident in the frontend for normal-size files, so scrolling never outruns the data and never shows blank or stale rows during a fast flick. This is on by default.

Two knobs gate it, and both must pass:

- `:resident_store_max_lines` (default `65536`): the maximum number of displayed rows the frontend can retain. A line that wraps to six rows counts as six. Set it to `0` to turn residence off and go back to the viewport-windowed path.
- `:resident_store_max_bytes` (default `10485760`, 10 MB): the maximum buffer byte size that still gets residence.

In practice the byte gate and the `:max_file_size` pre-load refusal (also 10 MB) bound the real exposure well below the line ceiling: files above `:max_file_size` never open at all, so they never reach the residence gate.

Folded buffers still use the viewport-windowed path. Wrapped files that exceed the residence limits also remain windowed, but still scroll to the final continuation.

To open a huge file instantly, residence engages on the frame after first paint: the first frame of a newly opened (or resized) file renders viewport-windowed so content appears immediately, then the full-document store is built on the next frame. You do not need to configure this; it is automatic.

## Per-filetype settings

Different languages have different conventions. `for_filetype/2` overrides global options for buffers of a specific language:

```elixir
for_filetype :go, tab_width: 8
for_filetype :python, tab_width: 4
for_filetype :elixir, tab_width: 2, autopair: true
```

When you open a Go file, `tab_width` is 8. When you open an Elixir file, it's 2. Buffers with no filetype (or filetypes without overrides) use the global value.

You can set any option that `set/2` accepts. The filetype atom matches what `Minga.Language.detect_filetype/1` detects (`:elixir`, `:go`, `:python`, `:rust`, `:javascript`, etc.).

## Formatters

`SPC c f` formats the current buffer using the configured formatter for its filetype. Minga ships default formatters for common languages:

| Language | Default formatter |
|----------|-------------------|
| Elixir | `mix format --stdin-filename {file} -` |
| Go | `gofmt` |
| Rust | `rustfmt --edition 2021` |
| Python | `python3 -m black --quiet -` |
| JavaScript/TypeScript | `prettier --stdin-filepath {file}` |
| Zig | `zig fmt --stdin` |
| C/C++ | `clang-format` |

The `{file}` placeholder is replaced with the buffer's file path (useful for formatters that need it to find their config).

### Format-on-save

Enable per-filetype with `for_filetype`:

```elixir
for_filetype :elixir, format_on_save: true
for_filetype :go, format_on_save: true, indent_with: :tabs, tab_width: 8
for_filetype :rust, format_on_save: true
```

When you save (`:w` or `SPC f s`), the buffer is formatted before writing to disk. If the formatter fails, the buffer is saved unformatted and the error appears in the status bar.

### Custom formatters

Override the default formatter for any filetype:

```elixir
for_filetype :elixir, formatter: "mix format --stdin-filename {file} -"
for_filetype :ruby, formatter: "rubocop --stdin {file} --autocorrect"
for_filetype :javascript, formatter: "deno fmt --ext=js -"
```

### Save transforms

Two additional options clean up whitespace on save:

```elixir
# Strip trailing whitespace from every line
for_filetype :elixir, trim_trailing_whitespace: true

# Ensure the file ends with a newline
for_filetype :elixir, insert_final_newline: true
```

These run before format-on-save, so the formatter gets clean input.

## Syntax highlighting

Minga uses [tree-sitter](https://tree-sitter.github.io/) for syntax highlighting. It bundles 50 tree-sitter grammars, which cover the languages below out of the box. Highlighting activates automatically when a file's type is detected. No configuration needed.

### Supported languages

| Language | Extensions |
|----------|-----------|
| Bash | `.sh`, `.bash`, `.zsh` |
| C | `.c`, `.h` |
| C# | `.cs`, `.csx` |
| C++ | `.cpp`, `.cc`, `.cxx`, `.hpp` |
| Clojure | `.clj`, `.cljs`, `.cljc`, `.edn` |
| CSS | `.css` |
| Dart | `.dart` |
| Diff | `.diff`, `.patch` |
| Dockerfile | `Dockerfile` |
| Elisp | `.el` |
| Elixir | `.ex`, `.exs` |
| Erlang | `.erl`, `.hrl` |
| Fish | `.fish` |
| Gleam | `.gleam` |
| Go | `.go` |
| GraphQL | `.graphql`, `.gql` |
| Haskell | `.hs`, `.lhs` |
| HCL / Terraform | `.tf`, `.tfvars`, `.hcl` |
| HEEx | `.heex`, `.leex` |
| HTML | `.html`, `.htm` |
| INI | `.ini`, `.editorconfig`, `.gitconfig`, `.gitmodules` |
| Java | `.java` |
| JavaScript | `.js`, `.mjs`, `.cjs`, `.jsx` |
| JSON | `.json`, `.jsonc` |
| Kotlin | `.kt`, `.kts` |
| Lua | `.lua` |
| Make | `Makefile`, `.mk`, `.mak` |
| Markdown | `.md`, `.markdown` |
| Nix | `.nix` |
| Objective-C | `.m`, `.mm` |
| OCaml | `.ml`, `.mli` |
| Perl | `.pl`, `.pm`, `.t` |
| PHP | `.php`, `.phtml` |
| Protobuf | `.proto` |
| Python | `.py`, `.pyi` |
| R | `.r`, `.rmd` |
| Ruby | `.rb`, `.rake`, `.gemspec` |
| Rust | `.rs` |
| Scala | `.scala`, `.sbt`, `.sc` |
| SCSS | `.scss`, `.sass` |
| SQL | `.sql` |
| Swift | `.swift` |
| TOML | `.toml` |
| TSX | `.tsx` |
| TypeScript | `.ts`, `.mts`, `.cts` |
| Vim script | `.vim`, `.vimrc` |
| XML | `.xml`, `.svg` |
| YAML | `.yaml`, `.yml` |
| Zig | `.zig`, `.zon` |

Each row is one grammar, except Markdown, which uses two: one for block structure and one for inline spans.

### Customizing highlight colors

Highlight colors come from your theme. Switching themes (`set :theme, :catppuccin_mocha`) changes all syntax colors at once. See [Themes](#themes) above.

### Overriding highlight queries

Each language's highlighting is driven by a tree-sitter query file (`.scm`). If you want to change what gets highlighted (for example, adding a capture for a language feature the default query misses), drop a custom query file at:

```
~/.config/minga/queries/{language}/highlights.scm
```

For example, to customize Elixir highlighting:

```
~/.config/minga/queries/elixir/highlights.scm
```

Your custom query completely replaces the built-in one for that language. Start by copying the default query from the Minga source (`zig/src/queries/{language}/highlights.scm`) and modifying it.

Queries use tree-sitter's [query syntax](https://tree-sitter.github.io/tree-sitter/syntax-highlighting/). The capture names Minga recognizes include: `@keyword`, `@string`, `@comment`, `@function`, `@type`, `@number`, `@operator`, `@punctuation`, `@variable`, `@constant`, and more. Each maps to a color slot in the active theme.

No restart is needed after changing a query file; `SPC h r` (hot reload) picks up the change.

### Custom captures with custom face styling

The full highlight customization flow lets you define your own capture names in a query file, then style them with custom faces in a theme. This is how you'd highlight something the default query doesn't distinguish.

**Example: highlight Elixir pipe operators differently from other operators.**

1. **Add a custom capture in your query.** Copy the default Elixir query and add a specific capture:

```
; ~/.config/minga/queries/elixir/highlights.scm
; (copy of the default query, plus:)

(binary_operator
  operator: "|>" @operator.pipe)
```

The capture `@operator.pipe` is a new name you invented. It follows the dotted naming convention so it inherits from `@operator` by default.

2. **Define a face for the capture in your theme file.** In your config:

```elixir
# In config.exs
Minga.Face.Registry.put(face_registry, %Minga.Face{
  name: "operator.pipe",
  inherit: "operator",
  fg: 0x51AFEF,
  bold: true
})
```

Or in a theme TOML file (when theme file loading is available):

```toml
[faces."operator.pipe"]
inherit = "operator"
fg = "51AFEF"
bold = true
```

3. **Reload.** Press `SPC h r` to pick up the query change. The pipe operator now renders in blue bold, while other operators keep their default style.

**How it works under the hood:**

- Tree-sitter matches `@operator.pipe` captures in the query and sends them to the BEAM.
- The face registry resolves `"operator.pipe"` by walking the inheritance chain: `operator.pipe` → `operator` → `default`. Your custom face overrides fg and bold; everything else inherits from the parent.
- The render pipeline uses the resolved face for styling. No special registration needed for new capture names; the dotted-name convention handles inheritance automatically.

**Built-in capture names** that themes can style include: `keyword`, `keyword.function`, `keyword.operator`, `string`, `string.special`, `comment`, `comment.documentation`, `function`, `function.method`, `function.builtin`, `function.macro`, `type`, `type.builtin`, `variable`, `variable.builtin`, `variable.parameter`, `constant`, `constant.builtin`, `number`, `boolean`, `operator`, `punctuation.delimiter`, `punctuation.bracket`, `punctuation.special`, `attribute`, `property`, `tag`, `label`, `namespace`, `module`, `constructor`, and more. Any dotted sub-capture (e.g., `keyword.return`) inherits from its parent (e.g., `keyword`) if no explicit face is defined.

### Registering custom filetypes

If Minga doesn't recognize a file extension, the preferred fix is a language pack: define a `%Minga.Language{}` in a pack and register it with `Minga.Language.Registry.register/2`. That one registration owns file extensions, exact filenames, shebangs, devicons, grammar metadata, formatter defaults, and LSP defaults together.

For temporary local overrides, you can still register a filetype mapping in config:

```elixir
# In config.exs
Minga.Language.Filetype.Registry.register(".astro", :astro)
Minga.Language.Filetype.Registry.register("Justfile", :just)
```

This tells Minga the filetype, but highlighting only works if a grammar for that language is compiled into the editor. See below for adding new grammars.

### Adding a new language grammar

Adding a grammar for a language Minga doesn't ship requires building from source. This involves five steps:

1. **Vendor the grammar**: copy the tree-sitter grammar's `src/` directory into `zig/vendor/grammars/{lang}/src/`. You need `parser.c` and optionally `scanner.c`.
2. **Add a highlight query**: place a `highlights.scm` at `zig/src/queries/{lang}/highlights.scm`. The grammar's upstream repo usually has one you can start from.
3. **Register in the Zig build**: add an entry to the `grammars` array in `zig/build.zig` with `has_scanner` set appropriately.
4. **Register in the highlighter**: in `zig/src/highlighter.zig`, add an `extern fn tree_sitter_{lang}()` declaration and an entry in the `languages` array.
5. **Register the language in a pack**: create a language module that returns `%Minga.Language{}` with its extensions, filenames, shebangs, grammar name, icon, formatter, and LSP defaults, then add that module to the bundled language pack's `language_modules/0` list.

After rebuilding (`mix compile`), the grammar is compiled into the binary and the language pack makes it available immediately.

If you add a grammar for a popular language, consider opening a PR so everyone gets it.

### Prettify symbols

When enabled, prettify-symbols replaces common operator text with Unicode equivalents in the display without modifying the buffer. For example, `->` renders as `→`, `!=` as `≠`, and `fn` as `λ` in Elixir.

```elixir
# In config.exs
set :prettify_symbols, true
```

This is off by default since it's a matter of taste. The substitutions are filetype-aware and only apply to actual operators (not text inside strings or comments), because they use tree-sitter highlight captures to identify what's an operator.

**Built-in substitutions include:**

| Source | Display | Languages |
|--------|---------|-----------|
| `->` | `→` | All |
| `=>` | `⇒` | All |
| `<-` | `←` | All |
| `!=` | `≠` | All |
| `>=` | `≥` | All |
| `<=` | `≤` | All |
| `\|>` | `▷` | All |
| `fn` | `λ` | Elixir, Rust |
| `lambda` | `λ` | Python |

The buffer content is never modified; only the display changes. Cursor movement skips over concealed text in normal mode and reveals it in insert mode (same as Neovim's `conceallevel=2`).

## Keybindings

Press `SPC h a` and type part of a command name or description to find it. Select a match to open its `*Help*` page without running the command. Use the command name from that page when you write a binding. For example, search for `format buffer`, then bind `:format_buffer`.

`bind/4` adds or overrides keybindings in any vim mode:

```elixir
# Normal mode: leader sequences and single-key overrides
bind :normal, "SPC g s", :git_status, "Git status"
bind :normal, "SPC g b", :git_blame, "Git blame"
bind :normal, "Q", :replay_last_macro, "Replay last macro"

# Insert mode
bind :insert, "C-j", :next_line, "Next line"
bind :insert, "C-k", :prev_line, "Previous line"

# Visual mode
bind :visual, "C-x", :custom_cut, "Custom cut"
```

The first argument is the mode: `:normal`, `:insert`, `:visual`, `:operator_pending`, or `:command`. The second is a space-separated key sequence string. Special keys:

| Token | Key |
|-------|-----|
| `SPC` | Space |
| `TAB` | Tab |
| `RET` | Return/Enter |
| `ESC` | Escape |
| `C-x` | Ctrl + x |
| `M-x` | Alt/Meta + x |

User bindings override defaults. If you bind `SPC f f` to something else, it replaces the built-in "Find file" binding.

Invalid key sequences log a warning but don't crash the editor.

### Filetype-scoped bindings (SPC m)

`SPC m` is reserved for filetype-specific leader bindings. Use the `keymap` block to define them:

```elixir
keymap :elixir do
  bind :normal, "SPC m t", :mix_test, "Run tests"
  bind :normal, "SPC m f", :mix_format, "Format with mix"
  bind :normal, "SPC m r", :iex_run, "Run in IEx"
end

keymap :go do
  bind :normal, "SPC m t", :go_test, "Go test"
  bind :normal, "SPC m b", :go_build, "Go build"
end
```

You can also use the explicit `filetype:` option for one-off bindings:

```elixir
bind :normal, "SPC m p", :markdown_preview, "Preview", filetype: :markdown
```

Different filetypes can use the same sub-key. `SPC m t` runs `mix test` in an Elixir buffer but `go test` in a Go buffer. The which-key popup shows only the bindings for the current buffer's filetype.

### Scope-specific bindings

Override or extend bindings for specific [keymap scopes](KEYMAP-SCOPES.md) using a `{scope, vim_state}` tuple:

```elixir
# Override agent scope keys
bind {:agent, :normal}, "y", :my_custom_yank, "Custom yank"
bind {:agent, :normal}, "~", :toggle_debug, "Toggle debug"

# Override file tree scope keys
bind {:file_tree, :normal}, "d", :tree_delete, "Delete file"
```

### Keymap scopes

Minga uses [keymap scopes](KEYMAP-SCOPES.md) to provide view-type-specific keybindings. Six scopes ship by default: `:editor` (normal editing), `:agent` (the agent view), `:file_tree` (file tree panel), `:git_status` (Git status panel), `:picker` and `:prompt`. Leader key bindings (`SPC ...`) work identically wherever you are not typing text. The [Key reference](AGENTIC-KEYMAP.md) lists the keys each one ships with.

For the full scope architecture and resolution order, see [Keymap Scopes](KEYMAP-SCOPES.md).

For key parser internals, see `Minga.Keymap.KeyParser`. For how the active keymap and bindings work, see `Minga.Keymap.Active` and `Minga.Keymap.Bindings`.

## Custom commands

`command/3` defines a named command that can be bound to keys and appears in the command palette (`SPC :`):

```elixir
command :count_todos, "Count TODOs in buffer" do
  content = Minga.API.content()
  count = content |> String.split("\n") |> Enum.count(&String.contains?(&1, "TODO"))
  Minga.API.message("#{count} TODOs found")
end

# Bind it to a key
bind :normal, "SPC c t", :count_todos, "Count TODOs"
```

Commands run inside a supervised Task. If your command raises an exception, the error shows in the status bar but the editor keeps running. You can't crash the editor with a buggy command.

The `Minga.API` module provides a user-friendly interface for common operations inside commands: `content/0`, `insert/1`, `cursor/0`, `move_to/2`, `save/0`, `message/1`, and more.

## Lifecycle hooks

`on/2` registers functions that fire on editor events:

```elixir
on :after_save, fn _buffer_pid, path ->
  if String.ends_with?(path, ".ex") do
    System.cmd("mix", ["format", path])
  end
end

on :after_open, fn _buffer_pid, path ->
  Minga.API.message("Opened: #{Path.basename(path)}")
end

on :on_mode_change, fn old_mode, new_mode ->
  IO.puts("Mode: #{old_mode} -> #{new_mode}")
end
```

### Supported events

| Event | Arguments | Fires when |
|-------|-----------|------------|
| `:after_save` | `(buffer_pid, file_path)` | After a successful file save |
| `:after_open` | `(buffer_pid, file_path)` | After opening a file |
| `:on_mode_change` | `(old_mode, new_mode)` | When the editor mode changes |

Hooks run asynchronously. A slow `:after_save` hook (like running a formatter) won't block your typing. Each hook runs in its own supervised process, so crashes are logged but don't affect the editor.

Multiple hooks on the same event fire in registration order.

For the hooks API, see `Minga.Config.Hooks`.

## Command advice

`advise/3` wraps an existing command with before or after logic. This is similar to Emacs's advice system, but crash-isolated.

Four phases are supported, matching Emacs's advice system:

| Phase | Signature | Behavior |
|-------|-----------|----------|
| `:before` | `fn state -> state end` | Transforms state before the command |
| `:after` | `fn state -> state end` | Transforms state after the command |
| `:around` | `fn execute, state -> state end` | Receives the original command; decides whether/how to call it |
| `:override` | `fn state -> state end` | Completely replaces the command |

`:around` is the most powerful. It receives the original command as a function, so you can conditionally skip it, call it multiple times, or wrap it with custom logic:

```elixir
# Only format if there are no diagnostics errors. If the buffer has
# errors, formatting often makes things worse.
advise :around, :format_buffer, fn execute, state ->
  errors =
    state
    |> MingaEditor.Extension.EditorAPI.active_buffer()
    |> Minga.Diagnostics.for_buffer()
    |> Enum.count(fn d -> d.severity == :error end)

  if errors == 0 do
    execute.(state)
  else
    MingaEditor.Extension.EditorAPI.notice(state, "Format skipped: #{errors} error(s)")
  end
end
```

`:override` replaces a command entirely. `:before` and `:after` still run around an overridden command, so you can override the core behavior while keeping other advice intact:

```elixir
# Turn formatting off for this project: the command now only says so
advise :override, :format_buffer, fn state ->
  MingaEditor.Extension.EditorAPI.notice(state, "Formatting is off in this project")
end
```

To add behavior to a command instead of replacing it, use `:after`. Advice runs inside the editor, so call helpers that take `state` rather than `Minga.API` functions, which message the editor and would wait on themselves:

```elixir
# Stage the file in git after every save
advise :after, :save, fn state ->
  alias MingaEditor.Extension.EditorAPI

  with buffer when is_pid(buffer) <- EditorAPI.active_buffer(state),
       path when is_binary(path) <- Minga.Buffer.file_path(buffer),
       {_output, 0} <- System.cmd("git", ["add", path], stderr_to_stdout: true) do
    EditorAPI.notice(state, "Saved and staged: #{Path.basename(path)}")
  else
    _not_staged -> state
  end
end
```

`:before` and `:after` handle simpler cases where you just need to transform state on the way in or out:

```elixir
# Ensure cursor is at line start before any search, so results
# are consistent regardless of where you were on the line
advise :before, :search_project, fn state ->
  Minga.API.move_to_column(0)
  state
end
```

Multiple advice functions for the same phase and command run in registration order. For `:around`, they nest outward (first registered is outermost). Crashes in any advice are logged and skipped; the editor keeps running.

### Tool advice outcomes

Editor commands keep the state-to-state callback contract shown above. Advised agent tools retain their result separately from advice state. Tool `:around` and `:override` callbacks return one of these tagged outcomes:

```elixir
{:returned, advice_state, tool_result}
{:skipped, advice_state}
```

Returning a bare advice-state map from tool `:around` or `:override` advice means skipped and produces `{:error, :no_result}` for the tool caller. The tool core always uses the arguments that passed approval and hooks; transforming advice state cannot replace those authorized arguments.

Existing tool `:before` and `:after` callbacks still receive and return a state map, so they need no signature migration. Tool-specific around callbacks must preserve the tagged outcome instead of treating `execute.(state)` as a bare map:

```elixir
advise :around, :read_file, fn execute, state ->
  case execute.(state) do
    {:returned, next_state, result} -> {:returned, next_state, result}
    {:skipped, _next_state} = skipped -> skipped
  end
end
```

An around or override callback can replace the result with an explicit `{:returned, state, replacement}`. If it fails or returns an invalid value, Minga skips that invocation and does not retry a core that already ran. Before or after failure preserves the prior advice state and retained tool result. Editor command advice behavior is unchanged.

### When to use advice vs. hooks

**Hooks** (`on/2`) are for fire-and-forget side effects: running an external tool after save, logging, sending notifications. They run asynchronously and can't change editor state.

**Advice** (`advise/3`) is for changing how a command behaves: conditionally skipping it, transforming editor state before or after it runs, or replacing the command entirely. Advice runs synchronously as part of the command, so it can affect what happens next.

For the advice API, see `Minga.Config.Advice`.

## Error handling

Minga is forgiving about config errors:

- **No config file**: editor starts with defaults, no error
- **Syntax error in config**: editor starts with defaults, error shown in status bar
- **Runtime error** (e.g., invalid option value): editor starts with defaults, error shown in status bar
- **Command crashes**: error shown in status bar, editor keeps running
- **Hook crashes**: error logged, other hooks still fire, editor keeps running

You can check for config load errors programmatically with `Minga.Config.Loader.load_error/0`.

## User modules

For anything beyond a quick command, you can write full Elixir modules. Drop `.ex` files in `~/.config/minga/modules/` and they're compiled and loaded at startup.

```elixir
# ~/.config/minga/modules/todo_tools.ex
defmodule TodoTools do
  def count(text) do
    text |> String.split("\n") |> Enum.count(&String.contains?(&1, "TODO"))
  end

  def list(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> String.contains?(line, "TODO") end)
    |> Enum.map(fn {line, num} -> "#{num}: #{String.trim(line)}" end)
    |> Enum.join("\n")
  end
end
```

Then reference it in your config:

```elixir
# ~/.config/minga/config.exs
use Minga.Config

command :list_todos, "List TODO lines" do
  {:ok, content} = Minga.API.content()
  Minga.API.message(TodoTools.list(content))
end

bind :normal, "SPC c t", :list_todos, "List TODOs"
```

If a module has a compile error, Minga logs a warning and skips that file. Other modules and your config still load normally.

## Project-local config

Drop a `.minga.exs` file in your project root to set project-specific options. Project config runs after global config, so it overrides global settings.

```elixir
# /path/to/my-project/.minga.exs
use Minga.Config

set :tab_width, 4
for_filetype :go, tab_width: 8

on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".go"), do: System.cmd("gofmt", ["-w", path])
end
```

This is useful for team-shared settings. Check `.minga.exs` into your repo and everyone on the team gets the same tab width, formatters, and hooks.

A project can carry two more things next to it: plugin folders in `.minga/plugins/`, and MCP servers in `.minga/mcp.json`. They follow the same rules as `.minga.exs`. One thing a plugin author meets first on macOS: files unpacked from an archive are often writable by their group, and a plugin that vendors such files is refused until you run `chmod -R g-w` on the plugin folder (the reason is in [Folders Minga will not load config from](#folders-minga-will-not-load-config-from)).

### Which project config is loaded

Project-local config is code: `.minga.exs` is Elixir that runs, a plugin is code Minga loads, and an MCP server is a command Minga starts. So Minga is exact about where it comes from. It is read from the root of the project you launched, never from whatever directory the editor process happens to run in.

- `minga lib/app.ex` or `minga ~/code/app` loads the config of that file's or folder's project.
- `minga` with no argument, typed in a terminal, opens the project of the directory you are in, and loads its config. This is how most people open a project, and it is the same rule that restores the project's session.
- Minga started without a terminal (from Finder or the Dock, or as a service) has no directory you chose, so it opens no project and loads no project config. Open a folder, then reload config (`SPC h r`), and the folder's config loads.
- A reload reads the project you have open at that moment.

`*Messages*` (`SPC b m`) says what happened: "Project config loaded from ~/code/app: .minga.exs, .minga/mcp.json", or why a folder's config was not loaded. With no project there is nothing to say.

A relative path in a config file, as in `extension :my_ext, path: "ext"` or the source folder you give `Minga.Language.register_grammar/3`, means next to that file. It does not depend on where you started Minga.

### Folders Minga will not load config from

A folder as broad as your home directory, a folder above it, `/`, or the top of a mounted volume is not treated as a project just because a marker file sits there, and its `.minga.exs`, plugins and MCP servers are not loaded. The one exception is version control: if that folder is a Git repository (a dotfiles setup, for example), it is a project and its config loads. This is the same rule that decides where Minga's Agent may work; see [Projects](PROJECTS.md#where-minga-works-when-there-is-no-project).

Config is also not loaded from a folder or a file that is not yours. The project folder, `.minga.exs`, the `.minga` folder, `.minga/mcp.json` and the plugins folder must belong to your account, and nobody else on the machine may be able to write them. This is what stops another account from leaving a `.minga.exs` in a shared folder such as `/tmp` for you to run. Minga follows a link first and judges what it leads to.

A folder of code is held to the same rule all the way down. That means each plugin in `.minga/plugins`, the folder an `extension ..., path:` in a project's config points at, and a grammar's source folder that a project's config registers. Every folder and every file in it must be yours and closed to others: the source files, `plugin.json`, the scripts its command lines name, and folders that are still empty, because a file someone adds there later would be loaded too. Minga registers such a folder under its real path, so a link that is pointed somewhere else afterwards changes nothing.

- **The folders above count too.** Each folder above the project, and above a folder of code, up to `/`, must belong to you or to the system, and others must not be able to write it. A sticky folder such as `/tmp` is fine, because there one account cannot rename or remove another account's entries. So `/tmp/my-project` loads its config, and a project inside another account's open folder does not.
- **A folder or file that anyone can write is refused** until you remove that access (`chmod o-w`, or `chmod -R o-w` for a whole folder).
- **Group write access depends on the platform.** On Linux it is allowed: an account usually has a group of its own, so a project folder shared with a group is shared on purpose, and that group can change what your editor runs. On macOS it is refused, because every account on a Mac is in the `staff` group, which makes "the group" everyone. Remove it with `chmod g-w` (`chmod -R g-w` for a whole folder; files unpacked from an archive often carry it).
- **A folder of code has a size limit.** Minga examines every entry in it at each load, so a plugin or extension folder with more than 10,000 files and folders is refused. Keep dependencies and build output out of it. (Examining 10,000 entries takes well under a second.)
- Minga reads the mode bits. An access control list (ACL) that grants someone else write access is not seen.

When a folder or a file is refused, `*Messages*` names it, says why, and says what would make it loadable. One refused file leaves the rest of the project's config loaded. Minga never falls back to a parent folder's config or to the directory it was started from.

On reload, the project you have open may be a different one from the project Minga started with. Its config loads, with one exception: extensions and plugins are admitted once, when Minga starts. If the other project's `.minga.exs` declares extensions, or it has a `.minga/plugins` folder, its config is left out, nothing of it is compiled, and `*Messages*` says to start Minga in that project.

**Note:** These rules are a floor against other accounts on your machine. They do not judge the project's own code, and Minga does not ask before it loads a project's config: opening a file inside a repository loads that repository's config and runs it. Review `.minga.exs`, `.minga/plugins` and `.minga/mcp.json` in a project you did not write before you open it.

### Programs a project's config starts

Some config makes Minga start a program: an MCP server, a hook, a formatter, a language server, a plugin's slash command. Minga judges what it starts itself, and it decides where the program runs. It does not judge what the program reads once it is running.

**Where it runs.** Every one of these runs in the root of the project, never in the directory Minga happened to be started from. So a relative path in a server, hook or formatter line means "in the project": `scripts/fmt.sh` is the project's `scripts/fmt.sh`, whether you ran `minga` inside the project or `cd /tmp && minga ~/code/app`. A plugin names its own files through `${MINGA_PLUGIN_ROOT}`, which Minga replaces with the plugin's real path. A project's config and a plugin cannot choose another directory: a `cwd` they supply is replaced.

**Which program runs.** For an MCP server that a project declares, in `.minga/mcp.json` or with `set :agent_mcp_servers` in its `.minga.exs`:

- A bare name such as `node` is your own environment. Minga looks it up when the server starts, on the `PATH` Minga has at that moment, and in absolute folders only. A relative or empty `PATH` entry is passed over, because it would mean "whatever directory this runs in". A program that is not installed shows up as a server that failed to start, and it is found the next time a conversation starts once you install it.
- A name with a `/` in it is a file in the project. Minga examines it when it loads the config, and what it starts later is exactly that file. It must exist, and it must be yours and closed to others, with every folder between the project root and it. If it is missing or fails, that server is left out and `*Messages*` says why and what to do; reload the config (`SPC h r`) once it is fixed.
- A path that ends up outside the project, whether you wrote an absolute path to a tool or a link of your own leads out of the project, is your own environment and only has to exist.

**What is not judged.** Arguments, environment values, and whatever the program reads or imports after it starts. A hook, a formatter and a language server command are shell lines: the line is the project's own code, as much as anything in `.minga.exs`, and only its directory is decided by Minga.

| What starts | Who can declare it | What Minga judges | Where it runs |
|-------------|--------------------|-------------------|---------------|
| MCP server in `.minga/mcp.json` | the project | the program (rules above) | the project root |
| MCP server or hook set in a project's `.minga.exs` | the project | the server's program; a hook is a shell line | the project root |
| A plugin's MCP server | a plugin (a project's plugin is examined file by file when it is registered) | the plugin's own relative program is resolved inside the plugin | the root of the project the session works in |
| A plugin's hook | a plugin | nothing: a shell line run by Minga's hook runner | the root of the project whose config is loaded |
| Language server | any config | nothing: a command line | the project root (as before) |
| Formatter | any config | nothing: a shell line | the open project's root |
| A plugin's slash command | a plugin | nothing | the open project's root |
| Agent status command | your own config | nothing: a shell line | the session's folder (as before) |

An MCP server from your own config starts in the folder the conversation works in, like every other server; in your own config you can give a server or a hook a `cwd` (an absolute path) to start it somewhere else. With no project open, a hook, a formatter or a slash command from your own config or a global extension runs where Minga runs, as it always did, and a conversation without a folder starts no MCP servers.


## Post-init hook (after.exs)

If you need config that depends on user modules being loaded first, put it in `~/.config/minga/after.exs`. This file runs last, after modules, global config, and project config.

```elixir
# ~/.config/minga/after.exs
use Minga.Config

# This works because TodoTools was compiled from modules/ first
set :tab_width, TodoTools.preferred_tab_width()
```

## Config reload

Press `SPC h r` to reload ordinary configuration without restarting the editor. Before changing runtime state, Minga fingerprints every admitted path and Git extension from a private source snapshot. If any source differs from the artifact admitted for the current VM generation, reload reports that a restart is required and leaves the running extension module, process, manifest version, and contributions unchanged. It does not compile the changed source.

Reload also fingerprints `~/.config/minga/modules/*.ex`. If those files changed, it reports that a fresh Minga process is required and leaves resident code and runtime state alone. When all compiled sources are unchanged, reload stops extension runtimes through their lifecycle Instances, keeps user modules resident, resets config-owned options, keybindings, hooks, advice, and commands, re-evaluates `config.exs`, `.minga.exs`, and `after.exs`, then starts extensions from their admitted artifacts. Changed data declarations take effect immediately. The status bar shows "Config reloaded" on success or an error message if something went wrong.

You can also reload from the command line with `:reload-config` (not yet wired as an ex command, use `SPC h r`).

## Load order

Minga loads config in this order. Each stage can override the previous one:

1. `~/.config/minga/modules/*.ex` (user modules, compiled alphabetically)
2. `~/.config/minga/config.exs` (global config)
3. `.minga.exs` at the root of the project you launched (project-local config; see [Which project config is loaded](#which-project-config-is-loaded))
4. `~/.config/minga/after.exs` (post-init hook)
5. Extensions are started (from declarations in steps 2-4)

## Extensions

Extensions are reusable, self-contained editor plugins. Each extension runs under its own supervisor, so a crash in one extension never affects others or the editor.

This section is the reference for installing, loading and updating extensions from your config. To decide whether you need one, read [Extending Minga](https://mingacode.dev/extending) on the site. To write one, start with [Your first extension](EXTENSION_API.md#your-first-extension) in the Extension API guide.

### Optional extensions

These extensions install only when you opt in. Add the lines you want to `config.exs` and restart Minga:

```elixir
extension :minga_adversarial, git: "https://github.com/jsmestad/minga-adversarial"
extension :minga_knowledge_graph, git: "https://github.com/jsmestad/minga-knowledge-graph"
extension :minga_ghost_cursors, git: "https://github.com/jsmestad/minga-ghost-cursors"
extension :minga_git_extended, git: "https://github.com/jsmestad/minga-git-extended"
```

If you used Knowledge Graph before this change, keep the name `:minga_knowledge_graph` to continue using your saved graph. The Git checkout is separate from its data.

GitExtended adds the Git status panel, staging, commits, and branch commands. The branch in the modeline and the changed-line signs in the gutter work without it.

If your config has `extension :git_porcelain`, replace it with the `:minga_git_extended` line above and restart Minga.

To disable an extension, remove its install line and restart Minga.

### Writing an extension

An extension is a directory containing `.ex` files, with one module that implements the `Minga.Extension` behaviour:

```elixir
# ~/code/minga_todo/extension.ex
defmodule MingaTodo do
  use Minga.Extension

  # Declare typed config options (validated at load time)
  option :keyword, :string,
    default: "TODO",
    description: "The keyword to scan for"

  option :highlight, :boolean,
    default: true,
    description: "Highlight TODO lines in the gutter"

  @impl true
  def name, do: :minga_todo

  @impl true
  def description, do: "TODO tracking and highlighting"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(config) do
    keyword = Keyword.get(config, :keyword, "TODO")
    {:ok, %{keyword: keyword}}
  end
end
```

Options declared with `option/3` are validated against their type when the extension loads. Users configure them directly in the extension declaration (see [Loading extensions](#loading-extensions) below). At runtime, read them with `Minga.Config.get_extension_option(:minga_todo, :keyword)`.

The `use Minga.Extension` macro also gives you a default `child_spec/1` that starts a simple Agent holding your config. Override `child_spec/1` if your extension needs a GenServer or a full supervision tree:

```elixir
defmodule MingaTodo do
  use Minga.Extension

  # ... name, description, version, init callbacks ...

  @impl true
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {MingaTodo.Server, :start_link, [config]},
      restart: :permanent,
      type: :worker
    }
  end
end
```

Extensions can register commands, keybindings, and hooks using the standard config API:

```elixir
# Inside your extension's init/1 or a supporting module
def init(config) do
  Minga.Config.bind(:normal, "SPC c t", :todo_list, "List TODOs")

  Minga.Config.register_command(:todo_list, "List TODO lines", fn ->
    {:ok, content} = Minga.API.content()
    todos = find_todos(content)
    Minga.API.message(todos)
  end)

  {:ok, config}
end
```

### Loading extensions

Extensions can be loaded from three sources: local paths, git repositories, and Hex packages. Declare them in your config file:

```elixir
# ~/.config/minga/config.exs
use Minga.Config

# Local path (for development or private extensions)
extension :minga_todo, path: "~/code/minga_todo"

# Git repository (bleeding-edge or private repos)
extension :minga_snippets, git: "https://github.com/user/minga-snippets"

# Hex package (published, versioned extensions)
extension :minga_tools, hex: "minga_tools", version: "~> 0.3"
```

Provide one source: `path:`, `git:`, or `hex:`. Extra keyword options (everything except the source and its sub-options like `branch:`, `app:`, or `version:`) are passed to the extension as config. If the extension declares typed options with `option/3`, these values are validated at load time:

```elixir
# Config options are grouped right in the extension declaration
extension :minga_org, git: "https://github.com/jsmestad/minga-org",
  conceal: false,
  pretty_bullets: true,
  heading_bullets: ["•", "◦"]
```

### Local path extensions

Point at a directory containing `.ex` files. The directory is compiled at startup. This is the best option when you're developing an extension or using something that isn't published anywhere.

```elixir
extension :my_ext, path: "~/code/my_ext"
extension :my_formatter, path: "~/code/my_formatter", format_cmd: "prettier --stdin"
```

Path extensions don't have an update mechanism. You manage the directory yourself (git pull, etc.).

### Git extensions

New Git checkouts live in `~/.local/share/minga/extension_sources/{name}/`, separate from extension data. Existing checkouts under `~/.local/share/minga/extensions/` stay in place. Subsequent startups use the cached checkout without a network request.

```elixir
# Track the default branch (main). Stays on last-fetched commit until you update.
extension :snippets, git: "https://github.com/user/minga-snippets"

# Track a specific branch
extension :snippets, git: "https://github.com/user/minga-snippets", branch: "develop"

# Pin to a tag or commit hash (updates are skipped for pinned extensions)
extension :snippets, git: "https://github.com/user/minga-snippets", ref: "v1.0.0"
extension :snippets, git: "https://github.com/user/minga-snippets", ref: "abc1234"
```

Both HTTPS and SSH URLs work (`git@github.com:user/repo.git`).

Omitting both `branch:` and `ref:` defaults to whatever the remote's default branch is (usually `main`).

### Hex extensions

Hex extensions are fetched and compiled via `Mix.install/2`, the same mechanism Livebook uses for notebook dependencies. This handles dependency resolution (including transitive deps), downloading, compilation, and code path setup.

```elixir
# Latest stable release, when the config name matches the package and OTP app
extension :minga_tools, hex: "minga_tools"

# Use app: when the config name is an alias for a differently named Hex/OTP app
extension :tools, hex: "minga_tools", app: :minga_tools

# Version constraint (standard Elixir/Hex semver syntax)
extension :tools, hex: "minga_tools", app: :minga_tools, version: "~> 0.3"
extension :tools, hex: "minga_tools", app: :minga_tools, version: ">= 1.0.0 and < 2.0.0"
extension :tools, hex: "minga_tools", app: :minga_tools, version: "== 0.3.1"
```

Omitting `version:` fetches the latest stable release. If the extension config name differs from the Hex package and OTP app name, pass `app:` explicitly so Minga can build the Mix dependency and start the correct application without atomizing package strings at runtime.

All hex extensions are installed in a single `Mix.install/2` call at startup. The results are cached (keyed on the dep list hash), so the second boot with the same extensions skips all network and compilation work. The cache lives at `~/.cache/mix/installs/`.

#### Hex extensions under the development launcher

If you work on Minga itself and run it with `bin/minga`, Minga runs inside its own Mix project (`mix minga`), and `Mix.install/2` refuses to run there. Minga handles this for you: it runs the install in a separate, short-lived BEAM process that has no Mix project, then loads the result through the same admission checks a release build uses. You declare the extension exactly as above, and it loads the way it does for users.

A few things differ from a release build:

- The build and install directory lives in Minga's data directory, at `$XDG_DATA_HOME/minga/hex_extension_installs/` (or `~/.local/share/minga/hex_extension_installs/`), and Minga keeps it private to your user. `bin/minga` points that directory at its private development profile, so the build never lands in your Mix project or in `~/.cache/mix/installs/`. The Hex package cache (`HEX_HOME`) and `MIX_HOME`, where the Hex client lives, are still shared with the rest of your machine.
- The extension compiles against the Minga modules from your checkout, so `minga_sdk` compiles no stubs. A dependency that Minga already ships (for example `jason`) uses Minga's copy.
- Minga refuses to load a dependency that would replace a Minga module. The install fails and names the conflicting module.
- The installer process does not receive Minga's provider keys (`OPENAI_API_KEY` and the other provider variables, `ANTHROPIC_*`, and `MINGA_GATEWAY_TOKEN`), because a package's compile-time code runs there.
- Loaded extension code stays in memory until Minga exits. If you change an extension's `version:` and reload your config, the reload fails with a message asking you to restart Minga to switch versions.

If the install fails (no network, a compile error, or a module conflict), `*Messages*` shows the reason with the tail of the installer's output (with credentials in URLs redacted), and `:extensions` lists the extension as `load_error`. To work around a failure, clone the extension and load it with `path:` instead:

```elixir
extension :claude_bridge, path: "~/code/minga-claude-bridge"
```

### Listing extensions

`SPC h e l` or `:extensions` (`:ext`) in command mode lists all loaded extensions with their source type:

```
Extensions:
  minga_todo v0.1.0 [running] (path: ~/code/minga_todo)
  snippets v0.2.0 [running] (git: https://github.com/user/minga-snippets)
  tools v0.3.1 [running] (hex: minga_tools)
```

### Updating extensions

Extensions don't auto-update on startup. You control when updates happen.

**Update all extensions:** Press `SPC h e u` (or run `:ExtUpdateAll`). Minga fetches remote changes for all git extensions in the background, then shows a confirmation dialog stepping through each available update:

```
snippets: abc1234 → def5678 (3 commits on main) [Y/n/d] (1 of 2)
```

The confirmation dialog supports three keys:

| Key | Action |
|-----|--------|
| `Y` | Accept this update and advance to the next |
| `n` | Skip this update and advance |
| `d` | Show details (recent git commit log) in *Messages* |
| `q` / `Escape` | Stop early, apply whatever you've accepted so far |

Pinned extensions (`ref: "v1.0.0"`) are shown as "pinned, skipped" and cannot be updated.

After you confirm, accepted updates are staged in the background by fast-forwarding their Git checkouts. Running modules and processes are not replaced. Minga emits a restart-required event and reports the staged revision in `*Messages*` (`SPC b m`); restart Minga to compile and activate it.

**Update a single extension:** Press `SPC h e U` (or run `:ExtUpdate`). A picker opens listing all extensions. Select one to check and update just that extension.

**Hex extensions:** Hex packages are cached by `Mix.install/2`. Dependency or version-constraint changes require a fresh Minga process; config reload does not reinstall or replace Hex code in the running VM.

### Staging failures

If a Git update cannot fast-forward, Minga reports the error in `*Messages*` and leaves the running generation unchanged. Compilation and admission happen only during a fresh Minga process, so an update never needs to roll active code back in place.

### Crash isolation

Each extension runs under its own supervisor. If an extension process crashes, it restarts automatically without affecting the editor or other extensions. If an extension fails to load (bad path, compile error, init failure), you get a clear error message and everything else keeps working.

### Extension lifecycle

- Extensions are compiled, validated, admitted, and started after all config files are evaluated at VM startup
- `SPC h r` refuses to disturb a running path or Git extension whose source changed and reports restart required
- With unchanged admitted artifacts, reload may restart runtime state but never purges or replaces extension code
- Git extensions cache at `~/.local/share/minga/extensions/`
- Hex extensions cache at `~/.cache/mix/installs/`

## Full example

```elixir
use Minga.Config

# ── Options ──────────────────────────────────────────────────────────
set :tab_width, 2
set :line_numbers, :relative
set :scroll_margin, 5
set :autopair, true
set :autopair_block, true
set :theme, :catppuccin_mocha
set :whichkey_layout, :float        # centered floating window (or :bottom)

# Font (GUI backend only; no effect in TUI mode)
set :font_family, "JetBrains Mono"
set :font_size, 14
set :font_weight, :regular
set :font_ligatures, true

# ── Agent ─────────────────────────────────────────────────────────────
set :startup_view, :agent           # boot into agentic view (default)
set :agent_auto_context, true       # load CLI file as preview context (default)
set :agent_tool_approval, :destructive
set :agent_destructive_tools, ["write_file", "edit_file", "delete_file", "shell", "git_stage", "git_commit", "rename"]

# ── Per-language ─────────────────────────────────────────────────────
for_filetype :elixir, format_on_save: true, trim_trailing_whitespace: true, insert_final_newline: true
for_filetype :go, tab_width: 8, indent_with: :tabs, format_on_save: true
for_filetype :python, tab_width: 4, format_on_save: true
for_filetype :ruby, tab_width: 2

# ── Keybindings ──────────────────────────────────────────────────────
bind :normal, "SPC g s", :git_status, "Git status"
bind :normal, "SPC c t", :count_todos, "Count TODOs"

# ── Commands ─────────────────────────────────────────────────────────
command :git_status, "Show git status" do
  {output, _} = System.cmd("git", ["status", "--short"])
  Minga.API.message(output)
end

command :count_todos, "Count TODOs in buffer" do
  content = Minga.API.content()
  count = content |> String.split("\n") |> Enum.count(&String.contains?(&1, "TODO"))
  Minga.API.message("#{count} TODOs found")
end

# ── Hooks ────────────────────────────────────────────────────────────
on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".ex"), do: System.cmd("mix", ["format", path])
end

# ── Command advice ───────────────────────────────────────────────────
# Skip formatting if the buffer has errors
advise :around, :format_buffer, fn execute, state ->
  errors =
    state
    |> MingaEditor.Extension.EditorAPI.active_buffer()
    |> Minga.Diagnostics.for_buffer()
    |> Enum.count(fn d -> d.severity == :error end)

  if errors == 0, do: execute.(state), else: state
end

# ── Extensions ───────────────────────────────────────────────────────
extension :minga_todo, path: "~/code/minga_todo"
extension :snippets, git: "https://github.com/user/minga-snippets", branch: "main"
extension :tools, hex: "minga_tools", app: :minga_tools, version: "~> 0.3"
```

## Further reading

- `Minga.Config`: the DSL module (`set`, `bind`, `command`, `on`, `advise`, `for_filetype`)
- `Minga.Config.Options`: typed option registry with per-filetype overrides
- `Minga.Config.Loader`: config file discovery and evaluation
- `Minga.Config.Hooks`: lifecycle hook registry
- `Minga.Config.Advice`: before/after command advice
- `Minga.Keymap.Active`: active keymap store (defaults + user overrides)
- `Minga.Keymap.KeyParser`: key sequence string parser
- `Minga.API`: user-friendly editor API for commands and eval
- `Minga.Editing.Formatter`: formatter execution and default formatter registry
- `Minga.Extension`: extension behaviour and lifecycle
- `Minga.Extension.Supervisor`: extension process management
- `Minga.Extension.Git`: git clone, fetch, update, and rollback
- `Minga.Extension.Hex`: Hex package resolution via Mix.install
- `Minga.Extension.Updater`: update orchestration with confirmation and rollback
- [Extension API](EXTENSION_API.md): public callbacks, macros, model routes, runtime grammar loading, and lifecycle ownership
