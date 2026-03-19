# Configuration

Minga is configured with real Elixir code. Your config file is `~/.config/minga/config.exs` (or `$XDG_CONFIG_HOME/minga/config.exs`). Press `SPC f p` to open it from inside the editor.

If the file doesn't exist, `SPC f p` creates it with a starter template.

## Quick start

```elixir
use Minga.Config

set :tab_width, 4
set :line_numbers, :relative
set :scroll_margin, 8
```

That's it. Save the file and restart Minga. Your options take effect immediately on startup.

## Options

`set/2` configures global editor options. These are the supported options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:tab_width` | positive integer | `2` | Number of spaces per indent level |
| `:line_numbers` | `:hybrid`, `:absolute`, `:relative`, `:none` | `:hybrid` | Line number display style |
| `:autopair` | boolean | `true` | Auto-insert matching brackets and quotes |
| `:scroll_margin` | non-negative integer | `5` | Lines to keep visible above/below cursor when scrolling |
| `:theme` | theme name atom | `:doom_one` | Color theme (see [Themes](#themes) below) |
| `:indent_with` | `:spaces` or `:tabs` | `:spaces` | Whether to indent with spaces or tab characters |
| `:trim_trailing_whitespace` | boolean | `false` | Strip trailing whitespace on save |
| `:insert_final_newline` | boolean | `false` | Ensure file ends with a newline on save |
| `:format_on_save` | boolean | `false` | Run the filetype's formatter before saving |
| `:formatter` | string or `nil` | `nil` | Override the default formatter command (see [Formatters](#formatters)) |
| `:title_format` | string | `"{filename} {dirty}({directory}) - Minga"` | Terminal window title format (see [Window Title](#window-title)) |
| `:recent_files_limit` | positive integer | `200` | Max recent files tracked per project |
| `:persist_recent_files` | boolean | `true` | Write recent file history to disk (see [Projects](PROJECTS.md)) |
| `:agent_tool_approval` | `:destructive`, `:all`, `:none` | `:destructive` | When to prompt before executing agent tools |
| `:agent_destructive_tools` | list of strings | `["write_file", "edit_file", "shell"]` | Which tools are classified as destructive |
| `:agent_session_retention_days` | positive integer | `30` | Days to keep saved agent sessions before auto-pruning |
| `:startup_view` | `:agent` or `:editor` | `:agent` | Which view to show on startup (see [Startup view](#startup-view) below) |
| `:agent_auto_context` | boolean | `true` | Load CLI file as agent preview context on startup |
| `:whichkey_layout` | `:bottom` or `:float` | `:bottom` | Which-key popup display mode (see [Which-key popup](#which-key-popup) below) |
| `:font_family` | string | `"Menlo"` | Font family or name (see [Fonts](#fonts) below) |
| `:font_size` | positive integer | `13` | Font size in points (see [Fonts](#fonts) below) |
| `:font_weight` | weight atom | `:regular` | Font weight (see [Fonts](#fonts) below) |
| `:font_ligatures` | boolean | `true` | Enable programming ligatures (see [Fonts](#fonts) below) |
| `:log_level` | `:debug`, `:info`, `:warning`, `:error`, `:none` | `:info` | Global minimum log level (see [Logging](#logging) below) |
| `:log_level_render` | log level or `:default` | `:default` | Log level for the render pipeline |
| `:log_level_lsp` | log level or `:default` | `:default` | Log level for LSP client communication |
| `:log_level_agent` | log level or `:default` | `:default` | Log level for AI agent providers |
| `:log_level_editor` | log level or `:default` | `:default` | Log level for general editor operations |

```elixir
set :tab_width, 2
set :line_numbers, :hybrid
set :autopair, true
set :scroll_margin, 5
set :theme, :catppuccin_mocha
set :font_family, "JetBrains Mono"
set :font_size, 14
set :font_weight, :regular
set :font_ligatures, true
```

Invalid values show a clear error. Setting `:tab_width` to `-1` tells you it must be a positive integer.

## Agent tool approval

When the AI agent wants to run a destructive tool (writing a file, editing a file, or running a shell command), Minga pauses and shows a confirmation prompt:

```
⚠ Execute shell: mix test?  [y]es  [n]o  [a]ll
```

- **y** or **Enter** approves the tool and lets it run.
- **n** rejects the tool. The agent gets "Tool rejected by user" as the result and continues its turn.
- **a** approves this tool and all remaining tools in the current turn without further prompts.

The approval mode resets at the start of each new agent turn.

### Controlling when approval is required

The `:agent_tool_approval` option controls the gate:

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
set :agent_destructive_tools, ["write_file", "edit_file", "shell"]

# Trust file edits, only prompt for shell commands
set :agent_destructive_tools, ["shell"]

# Add a custom tool to the list
set :agent_destructive_tools, ["write_file", "edit_file", "shell", "deploy"]

# Empty list with :destructive mode = no prompts for built-in tools
set :agent_destructive_tools, []
```

The two options are orthogonal. `:agent_tool_approval` controls *whether* to prompt. `:agent_destructive_tools` controls *which tools* count as destructive when the mode is `:destructive`.

For the full option API, see [`Minga.Config.Options`](https://jsmestad.github.io/minga/Minga.Config.Options.html).

### Planned: buffer-aware agent options

When agent tools are [routed through `Buffer.Server`](BUFFER-AWARE-AGENTS.md), additional configuration options will control the new editing behavior:

- Whether agent edits auto-save to disk or stay in-memory until explicit save
- Whether buffer forks merge automatically (clean merges only) or always go through diff review
- Whether to flush dirty buffers before agent shell commands

These options don't exist yet. See [BUFFER-AWARE-AGENTS.md](BUFFER-AWARE-AGENTS.md) for the design.

## Startup view

Minga boots into the full-screen agentic view by default. The chat panel is visible, the input is focused, and an agent session starts automatically. You're ready to talk to the agent the moment Minga opens.

If you pass a file on the command line (`minga foo.ex`), the file opens in the preview pane so the agent has context about what you're working on.

### Switching to editor-first startup

If you prefer the traditional file editing experience on startup, set `:startup_view` to `:editor`:

```elixir
set :startup_view, :editor
```

This restores the pre-1.0 behavior: Minga opens with a file buffer (or scratch buffer) and the agentic view is a toggle away via `SPC a t`.

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
| `:doom_one` | Dark (default), Doom Emacs |
| `:catppuccin_frappe` | Dark, Catppuccin family |
| `:catppuccin_latte` | Light, Catppuccin family |
| `:catppuccin_macchiato` | Dark, Catppuccin family |
| `:catppuccin_mocha` | Dark, Catppuccin family |
| `:one_dark` | Dark, Atom |
| `:one_light` | Light, Atom |

The theme picker (`SPC h t`) live-previews each theme as you navigate the list. Selecting one applies it for the current session. To make it permanent, add the `set :theme` line to your config file.

For theme internals, see [`Minga.Theme`](https://jsmestad.github.io/minga/Minga.Theme.html).

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

### Subsystems

| Subsystem | Option | What it covers |
|-----------|--------|----------------|
| render | `:log_level_render` | Render pipeline stage timing and frame composition |
| lsp | `:log_level_lsp` | LSP server communication, requests, and errors |
| agent | `:log_level_agent` | AI agent providers, sessions, and tool execution |
| editor | `:log_level_editor` | General editor operations, commands, and file I/O |

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

## Per-filetype settings

Different languages have different conventions. `for_filetype/2` overrides global options for buffers of a specific language:

```elixir
for_filetype :go, tab_width: 8
for_filetype :python, tab_width: 4
for_filetype :elixir, tab_width: 2, autopair: true
```

When you open a Go file, `tab_width` is 8. When you open an Elixir file, it's 2. Buffers with no filetype (or filetypes without overrides) use the global value.

You can set any option that `set/2` accepts. The filetype atom matches what [`Minga.Filetype`](https://jsmestad.github.io/minga/Minga.Filetype.html) detects (`:elixir`, `:go`, `:python`, `:rust`, `:javascript`, etc.).

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

Minga uses [tree-sitter](https://tree-sitter.github.io/) for syntax highlighting. 39 languages are supported out of the box. Highlighting activates automatically when a file's type is detected. No configuration needed.

### Supported languages

| Language | Extensions |
|----------|-----------|
| Bash | `.sh`, `.bash`, `.zsh` |
| C | `.c`, `.h` |
| C# | `.cs`, `.csx` |
| C++ | `.cpp`, `.cc`, `.cxx`, `.hpp` |
| CSS | `.css` |
| Dart | `.dart` |
| Diff | `.diff`, `.patch` |
| Dockerfile | `Dockerfile` |
| Elisp | `.el` |
| Elixir | `.ex`, `.exs` |
| Erlang | `.erl`, `.hrl` |
| Gleam | `.gleam` |
| Go | `.go` |
| GraphQL | `.graphql`, `.gql` |
| Haskell | `.hs`, `.lhs` |
| HCL / Terraform | `.tf`, `.tfvars`, `.hcl` |
| HEEx | `.heex`, `.leex` |
| HTML | `.html`, `.htm` |
| Java | `.java` |
| JavaScript | `.js`, `.mjs`, `.cjs`, `.jsx` |
| JSON | `.json`, `.jsonc` |
| Kotlin | `.kt`, `.kts` |
| Lua | `.lua` |
| Make | `Makefile`, `.mk`, `.mak` |
| Markdown | `.md`, `.markdown` |
| Nix | `.nix` |
| OCaml | `.ml`, `.mli` |
| PHP | `.php`, `.phtml` |
| Python | `.py`, `.pyi` |
| R | `.r`, `.rmd` |
| Ruby | `.rb`, `.rake`, `.gemspec` |
| Rust | `.rs` |
| Scala | `.scala`, `.sbt`, `.sc` |
| SCSS | `.scss`, `.sass` |
| TOML | `.toml` |
| TSX | `.tsx` |
| TypeScript | `.ts`, `.mts`, `.cts` |
| YAML | `.yaml`, `.yml` |
| Zig | `.zig`, `.zon` |

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

If Minga doesn't recognize a file extension, you can register it in your config so the right grammar is used:

```elixir
# In config.exs
Minga.Filetype.Registry.register(".astro", :astro)
Minga.Filetype.Registry.register("Justfile", :just)
```

This tells Minga the filetype, but highlighting only works if a grammar for that language is compiled into the editor. See below for adding new grammars.

### Adding a new language grammar

Adding a grammar for a language Minga doesn't ship requires building from source. This involves five steps:

1. **Vendor the grammar**: copy the tree-sitter grammar's `src/` directory into `zig/vendor/grammars/{lang}/src/`. You need `parser.c` and optionally `scanner.c`.
2. **Add a highlight query**: place a `highlights.scm` at `zig/src/queries/{lang}/highlights.scm`. The grammar's upstream repo usually has one you can start from.
3. **Register in the Zig build**: add an entry to the `grammars` array in `zig/build.zig` with `has_scanner` set appropriately.
4. **Register in the highlighter**: in `zig/src/highlighter.zig`, add an `extern fn tree_sitter_{lang}()` declaration and an entry in the `languages` array.
5. **Register the filetype**: add extension/filename mappings in `lib/minga/filetype.ex` so files are detected correctly.

After rebuilding (`mix compile`), the grammar is compiled into the binary and available immediately.

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

Minga uses [keymap scopes](KEYMAP-SCOPES.md) to provide view-type-specific keybindings. Three scopes ship by default: `:editor` (normal editing), `:agent` (agentic view), and `:file_tree` (file tree panel). Leader key bindings (`SPC ...`) work identically in all scopes.

For the full scope architecture and resolution order, see [Keymap Scopes](KEYMAP-SCOPES.md).

For key parser internals, see [`Minga.Keymap.KeyParser`](https://jsmestad.github.io/minga/Minga.Keymap.KeyParser.html). For how the keymap trie works, see [`Minga.Keymap.Store`](https://jsmestad.github.io/minga/Minga.Keymap.Store.html) and [`Minga.Keymap.Trie`](https://jsmestad.github.io/minga/Minga.Keymap.Trie.html).

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

The [`Minga.API`](https://jsmestad.github.io/minga/Minga.API.html) module provides a user-friendly interface for common operations inside commands: `content/0`, `insert/1`, `cursor/0`, `move_to/2`, `save/0`, `message/1`, and more.

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

For the hooks API, see [`Minga.Config.Hooks`](https://jsmestad.github.io/minga/Minga.Config.Hooks.html).

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
    state.buffers.active
    |> Minga.Diagnostics.for_buffer()
    |> Enum.count(fn d -> d.severity == :error end)

  if errors == 0 do
    execute.(state)
  else
    %{state | status_msg: "Format skipped: #{errors} error(s)"}
  end
end
```

`:override` replaces a command entirely. `:before` and `:after` still run around an overridden command, so you can override the core behavior while keeping other advice intact:

```elixir
# Replace the built-in save with one that also stages the file in git
advise :override, :save, fn state ->
  # Run the original save logic
  state = Minga.API.save()

  # Then auto-stage
  case Minga.Buffer.Server.file_path(state.buffers.active) do
    nil -> state
    path ->
      System.cmd("git", ["add", path], stderr_to_stdout: true)
      %{state | status_msg: "Saved and staged: #{Path.basename(path)}"}
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

### When to use advice vs. hooks

**Hooks** (`on/2`) are for fire-and-forget side effects: running an external tool after save, logging, sending notifications. They run asynchronously and can't change editor state.

**Advice** (`advise/3`) is for changing how a command behaves: conditionally skipping it, transforming editor state before or after it runs, or replacing the command entirely. Advice runs synchronously as part of the command, so it can affect what happens next.

For the advice API, see [`Minga.Config.Advice`](https://jsmestad.github.io/minga/Minga.Config.Advice.html).

## Error handling

Minga is forgiving about config errors:

- **No config file**: editor starts with defaults, no error
- **Syntax error in config**: editor starts with defaults, error shown in status bar
- **Runtime error** (e.g., invalid option value): editor starts with defaults, error shown in status bar
- **Command crashes**: error shown in status bar, editor keeps running
- **Hook crashes**: error logged, other hooks still fire, editor keeps running

You can check for config load errors programmatically with [`Minga.Config.Loader.load_error/0`](https://jsmestad.github.io/minga/Minga.Config.Loader.html#load_error/0).

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

**Note:** Project-local config is real Elixir code that runs when you open the editor in that directory. Review `.minga.exs` files in untrusted projects before opening them.

## Post-init hook (after.exs)

If you need config that depends on user modules being loaded first, put it in `~/.config/minga/after.exs`. This file runs last, after modules, global config, and project config.

```elixir
# ~/.config/minga/after.exs
use Minga.Config

# This works because TodoTools was compiled from modules/ first
set :tab_width, TodoTools.preferred_tab_width()
```

## Hot reload

Press `SPC h r` to reload your config without restarting the editor. This:

1. Stops all running extensions
2. Purges user modules
3. Resets options, keybindings, hooks, advice, and commands to defaults
4. Re-compiles modules, re-evaluates config.exs, .minga.exs, and after.exs
5. Restarts extensions

Changed keybindings and options take effect immediately. The status bar shows "Config reloaded" on success or an error message if something went wrong.

You can also reload from the command line with `:reload-config` (not yet wired as an ex command, use `SPC h r`).

## Load order

Minga loads config in this order. Each stage can override the previous one:

1. `~/.config/minga/modules/*.ex` (user modules, compiled alphabetically)
2. `~/.config/minga/config.exs` (global config)
3. `.minga.exs` in the current working directory (project-local config)
4. `~/.config/minga/after.exs` (post-init hook)
5. Extensions are started (from declarations in steps 2-4)

## Extensions

Extensions are reusable, self-contained editor plugins. Each extension runs under its own supervisor, so a crash in one extension never affects others or the editor.

### Writing an extension

An extension is a directory containing `.ex` files, with one module that implements the `Minga.Extension` behaviour:

```elixir
# ~/code/minga_todo/extension.ex
defmodule MingaTodo do
  use Minga.Extension

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

The `use Minga.Extension` macro gives you a default `child_spec/1` that starts a simple Agent holding your config. Override `child_spec/1` if your extension needs a GenServer or a full supervision tree:

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

Exactly one of `path:`, `git:`, or `hex:` is required. Extra keyword options (everything except the source option) are passed to the extension's `init/1` callback.

### Local path extensions

Point at a directory containing `.ex` files. The directory is compiled at startup. This is the best option when you're developing an extension or using something that isn't published anywhere.

```elixir
extension :my_ext, path: "~/code/my_ext"
extension :my_formatter, path: "~/code/my_formatter", format_cmd: "prettier --stdin"
```

Path extensions don't have an update mechanism. You manage the directory yourself (git pull, etc.).

### Git extensions

Git extensions are cloned to `~/.local/share/minga/extensions/{name}/` on first load. Subsequent startups use the cached checkout without touching the network, so the editor boots reliably even when GitHub is down.

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
# Latest stable release
extension :tools, hex: "minga_tools"

# Version constraint (standard Elixir/Hex semver syntax)
extension :tools, hex: "minga_tools", version: "~> 0.3"
extension :tools, hex: "minga_tools", version: ">= 1.0.0 and < 2.0.0"
extension :tools, hex: "minga_tools", version: "== 0.3.1"
```

Omitting `version:` fetches the latest stable release.

All hex extensions are installed in a single `Mix.install/2` call at startup. The results are cached (keyed on the dep list hash), so the second boot with the same extensions skips all network and compilation work. The cache lives at `~/.cache/mix/installs/`.

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

After you confirm, accepted updates are applied in the background: git repos are fast-forwarded, extensions are recompiled and restarted. Results appear in `*Messages*` (`SPC b m`).

**Update a single extension:** Press `SPC h e U` (or run `:ExtUpdate`). A picker opens listing all extensions. Select one to check and update just that extension.

**Hex extensions:** Hex packages are cached by `Mix.install/2`. To pick up version changes, update the version constraint in your config and run `SPC h r` (config reload), which calls `Mix.install/2` with `force: true` to re-resolve and recompile.

### Rollback on failure

If an extension fails to compile after a git update, Minga automatically rolls back to the previous commit using the git reflog. The error is reported in `*Messages*` and the extension stays at its last working version. Other extensions continue updating normally.

### Crash isolation

Each extension runs under its own supervisor. If an extension process crashes, it restarts automatically without affecting the editor or other extensions. If an extension fails to load (bad path, compile error, init failure), you get a clear error message and everything else keeps working.

### Extension lifecycle

- Extensions are compiled and started after all config files are evaluated
- `SPC h r` stops all extensions, reloads config, then restarts them
- Extension state is lost on reload (the process restarts fresh)
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
set :agent_destructive_tools, ["write_file", "edit_file", "shell"]

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
    state.buffers.active
    |> Minga.Diagnostics.for_buffer()
    |> Enum.count(fn d -> d.severity == :error end)

  if errors == 0, do: execute.(state), else: state
end

# ── Extensions ───────────────────────────────────────────────────────
extension :minga_todo, path: "~/code/minga_todo"
extension :snippets, git: "https://github.com/user/minga-snippets", branch: "main"
extension :tools, hex: "minga_tools", version: "~> 0.3"
```

## Further reading

- [`Minga.Config`](https://jsmestad.github.io/minga/Minga.Config.html): the DSL module (`set`, `bind`, `command`, `on`, `advise`, `for_filetype`)
- [`Minga.Config.Options`](https://jsmestad.github.io/minga/Minga.Config.Options.html): typed option registry with per-filetype overrides
- [`Minga.Config.Loader`](https://jsmestad.github.io/minga/Minga.Config.Loader.html): config file discovery and evaluation
- [`Minga.Config.Hooks`](https://jsmestad.github.io/minga/Minga.Config.Hooks.html): lifecycle hook registry
- [`Minga.Config.Advice`](https://jsmestad.github.io/minga/Minga.Config.Advice.html): before/after command advice
- [`Minga.Keymap.Store`](https://jsmestad.github.io/minga/Minga.Keymap.Store.html): mutable keymap (defaults + user overrides)
- [`Minga.Keymap.KeyParser`](https://jsmestad.github.io/minga/Minga.Keymap.KeyParser.html): key sequence string parser
- [`Minga.API`](https://jsmestad.github.io/minga/Minga.API.html): user-friendly editor API for commands and eval
- [`Minga.Formatter`](https://jsmestad.github.io/minga/Minga.Formatter.html): formatter execution and default formatter registry
- [`Minga.Extension`](https://jsmestad.github.io/minga/Minga.Extension.html): extension behaviour and lifecycle
- [`Minga.Extension.Supervisor`](https://jsmestad.github.io/minga/Minga.Extension.Supervisor.html): extension process management
- [`Minga.Extension.Git`](https://jsmestad.github.io/minga/Minga.Extension.Git.html): git clone, fetch, update, and rollback
- [`Minga.Extension.Hex`](https://jsmestad.github.io/minga/Minga.Extension.Hex.html): Hex package resolution via Mix.install
- [`Minga.Extension.Updater`](https://jsmestad.github.io/minga/Minga.Extension.Updater.html): update orchestration with confirmation and rollback
- [Elixir is Minga's Elisp](https://jsmestad.github.io/minga/extensibility.html): deep dive on how the BEAM enables Emacs-level extensibility
