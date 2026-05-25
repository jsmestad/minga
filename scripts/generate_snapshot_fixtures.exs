#!/usr/bin/env elixir
# Generates pre-recorded render command streams for minga-snapshot testing.
#
# Each fixture is a binary file containing {:packet, 4} framed render commands
# that minga-snapshot can consume from stdin.
#
# Usage: mix run scripts/generate_snapshot_fixtures.exs

alias MingaEditor.Frontend.Protocol

defmodule FixtureWriter do
  @moduledoc false

  @spec write_fixture(String.t(), [binary()]) :: :ok
  def write_fixture(name, commands) do
    dir = Path.join([File.cwd!(), "zig", "tests", "fixtures"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}.bin")

    data =
      Enum.map(commands, fn cmd ->
        <<byte_size(cmd)::32, cmd::binary>>
      end)

    File.write!(path, data)
    IO.puts("Generated: #{path} (#{length(commands)} commands)")
  end
end

# Fixture 1: Syntax-highlighted code with multiple highlight groups
syntax_commands = [
  Protocol.encode_set_window_bg(0x282C34),
  Protocol.encode_clear(),
  # Line 1: "defmodule MyApp do" with keyword, type, keyword colors
  Protocol.encode_draw(0, 0, "defmodule", fg: 0xC678DD, bg: 0x282C34),
  Protocol.encode_draw(0, 10, "MyApp", fg: 0xE5C07B, bg: 0x282C34, bold: true),
  Protocol.encode_draw(0, 16, "do", fg: 0xC678DD, bg: 0x282C34),
  # Line 2: "  @moduledoc \"A sample module\""
  Protocol.encode_draw(1, 0, "  @moduledoc", fg: 0xDA8548, bg: 0x282C34),
  Protocol.encode_draw(1, 13, " \"A sample module\"", fg: 0x98C379, bg: 0x282C34),
  # Line 3: ""
  # Line 4: "  def hello(name) do"
  Protocol.encode_draw(3, 0, "  def", fg: 0xC678DD, bg: 0x282C34),
  Protocol.encode_draw(3, 6, "hello", fg: 0x61AFEF, bg: 0x282C34),
  Protocol.encode_draw(3, 11, "(", fg: 0xABB2BF, bg: 0x282C34),
  Protocol.encode_draw(3, 12, "name", fg: 0xE06C75, bg: 0x282C34),
  Protocol.encode_draw(3, 16, ")", fg: 0xABB2BF, bg: 0x282C34),
  Protocol.encode_draw(3, 18, " do", fg: 0xC678DD, bg: 0x282C34),
  # Line 5: "    IO.puts(\"Hello, #{name}!\")"
  Protocol.encode_draw(4, 0, "    IO", fg: 0xE5C07B, bg: 0x282C34),
  Protocol.encode_draw(4, 6, ".", fg: 0xABB2BF, bg: 0x282C34),
  Protocol.encode_draw(4, 7, "puts", fg: 0x61AFEF, bg: 0x282C34),
  Protocol.encode_draw(4, 11, "(", fg: 0xABB2BF, bg: 0x282C34),
  Protocol.encode_draw(4, 12, "\"Hello, ", fg: 0x98C379, bg: 0x282C34),
  Protocol.encode_draw(4, 20, "\#{name}", fg: 0xE06C75, bg: 0x282C34),
  Protocol.encode_draw(4, 27, "!\"", fg: 0x98C379, bg: 0x282C34),
  Protocol.encode_draw(4, 29, ")", fg: 0xABB2BF, bg: 0x282C34),
  # Line 6: "  end"
  Protocol.encode_draw(5, 0, "  end", fg: 0xC678DD, bg: 0x282C34),
  # Line 7: "end"
  Protocol.encode_draw(6, 0, "end", fg: 0xC678DD, bg: 0x282C34),
  # Cursor on line 4, col 12
  Protocol.encode_cursor(3, 12),
  Protocol.encode_batch_end()
]

FixtureWriter.write_fixture("syntax_highlight", syntax_commands)

# Fixture 2: Status bar with mode indicator and file info
status_commands = [
  Protocol.encode_set_window_bg(0x282C34),
  Protocol.encode_clear(),
  # Editor content area
  Protocol.encode_draw(0, 0, "Hello, world!", fg: 0xABB2BF, bg: 0x282C34),
  Protocol.encode_draw(1, 0, "This is a test file.", fg: 0xABB2BF, bg: 0x282C34),
  # Status bar at row 23 (bottom of 24-row terminal)
  # Mode indicator: NORMAL
  Protocol.encode_draw(23, 0, " NORMAL ", fg: 0x282C34, bg: 0x98C379, bold: true),
  # Git branch
  Protocol.encode_draw(23, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
  # File name
  Protocol.encode_draw(23, 16, " test.ex ", fg: 0xABB2BF, bg: 0x3E4452),
  # File type
  Protocol.encode_draw(23, 26, " elixir ", fg: 0x61AFEF, bg: 0x3E4452),
  # Position indicator (right-aligned)
  Protocol.encode_draw(23, 70, " Ln 1, Col 1 ", fg: 0xABB2BF, bg: 0x3E4452),
  # Cursor
  Protocol.encode_cursor(0, 0),
  Protocol.encode_cursor_shape(:block),
  Protocol.encode_batch_end()
]

FixtureWriter.write_fixture("status_bar", status_commands)

# Fixture 3: File tree / completion overlay
overlay_commands = [
  Protocol.encode_set_window_bg(0x282C34),
  Protocol.encode_clear(),
  # File tree panel (left side, cols 0-29)
  Protocol.encode_draw(0, 0, "  FILE TREE", fg: 0x5C6370, bg: 0x21252B, bold: true),
  Protocol.encode_draw(1, 0, "  > lib/", fg: 0xE5C07B, bg: 0x21252B, bold: true),
  Protocol.encode_draw(2, 0, "      minga.ex", fg: 0xABB2BF, bg: 0x21252B),
  Protocol.encode_draw(3, 0, "    > minga/", fg: 0xE5C07B, bg: 0x21252B),
  Protocol.encode_draw(4, 0, "        buffer.ex", fg: 0xABB2BF, bg: 0x21252B),
  Protocol.encode_draw(5, 0, "        config.ex", fg: 0x61AFEF, bg: 0x282C34),
  Protocol.encode_draw(6, 0, "        editor.ex", fg: 0xABB2BF, bg: 0x21252B),
  Protocol.encode_draw(7, 0, "        keymap.ex", fg: 0xABB2BF, bg: 0x21252B),
  Protocol.encode_draw(8, 0, "  > test/", fg: 0xE5C07B, bg: 0x21252B),
  Protocol.encode_draw(9, 0, "  > zig/", fg: 0xE5C07B, bg: 0x21252B),
  Protocol.encode_draw(10, 0, "    mix.exs", fg: 0xABB2BF, bg: 0x21252B),
  # Editor content area (right side)
  Protocol.encode_draw(0, 30, "use Minga.Config", fg: 0xC678DD, bg: 0x282C34),
  Protocol.encode_draw(1, 30, "", fg: 0xABB2BF, bg: 0x282C34),
  Protocol.encode_draw(2, 30, "config :editor do", fg: 0xC678DD, bg: 0x282C34),
  Protocol.encode_draw(3, 30, "  set :theme, \"doom-one\"", fg: 0xABB2BF, bg: 0x282C34),
  Protocol.encode_draw(4, 30, "  set :font_size, 14", fg: 0xABB2BF, bg: 0x282C34),
  Protocol.encode_draw(5, 30, "end", fg: 0xC678DD, bg: 0x282C34),
  Protocol.encode_cursor(5, 3),
  Protocol.encode_batch_end()
]

FixtureWriter.write_fixture("file_tree", overlay_commands)

# Fixture 4: Integrated full editor scene with sidebar, editor body, completion popup, and status bar.
full_editor_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    Enum.map(0..22, fn row ->
      Protocol.encode_draw(row, 0, String.duplicate(" ", 24), fg: 0xABB2BF, bg: 0x21252B)
    end) ++
    Enum.map(0..22, fn row ->
      Protocol.encode_draw(row, 24, "│", fg: 0x3E4452, bg: 0x282C34)
    end) ++
    [
      Protocol.encode_draw(0, 2, "FILE TREE", fg: 0x5C6370, bg: 0x21252B, bold: true),
      Protocol.encode_draw(1, 2, "▾ lib", fg: 0x61AFEF, bg: 0x21252B),
      Protocol.encode_draw(2, 4, "▾ minga", fg: 0x61AFEF, bg: 0x21252B),
      Protocol.encode_draw(3, 6, "editor.ex", fg: 0x61AFEF, bg: 0x2B4A73, bold: true),
      Protocol.encode_draw(4, 6, "buffer.ex", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(5, 6, "▸ mode", fg: 0x61AFEF, bg: 0x21252B),
      Protocol.encode_draw(6, 2, "▸ test", fg: 0x61AFEF, bg: 0x21252B),
      Protocol.encode_draw(7, 2, "▸ zig", fg: 0x61AFEF, bg: 0x21252B),
      Protocol.encode_draw(1, 28, "defmodule Minga.Editor do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(2, 30, "alias Minga.Buffer", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(4, 30, "def open(path) do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(5, 32, "{:ok, buffer} = Buffer.open(path)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(6, 32, "render(buffer)", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(7, 30, "end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(8, 28, "end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(10, 32, " defmodule                         keyword ", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(11, 32, " defstruct                         keyword ", fg: 0xDFDFDF, bg: 0x2257A0, bold: true),
      Protocol.encode_draw(12, 32, " defdelegate                       keyword ", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(13, 32, " def                               keyword ", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(14, 32, " Document             Minga.Buffer.Document ", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(23, 0, " NORMAL ", fg: 0x282C34, bg: 0x98C379, bold: true),
      Protocol.encode_draw(23, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 16, " editor.ex [+] ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 62, " ⚠ 2  Elixir ", fg: 0xE5C07B, bg: 0x282C34),
      Protocol.encode_draw(23, 74, "42:9", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_cursor(4, 34),
      Protocol.encode_cursor_shape(:beam),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("full_editor", full_editor_commands)

# ── Helper: draw a full row of spaces with a given bg color ──

defmodule FixtureHelpers do
  @moduledoc false

  @spec fill_row(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: binary()
  def fill_row(row, bg, cols \\ 80) do
    Protocol.encode_draw(row, 0, String.duplicate(" ", cols), fg: 0xABB2BF, bg: bg)
  end

  @spec editor_bg_rows(Range.t()) :: [binary()]
  def editor_bg_rows(range) do
    Enum.map(range, fn row -> fill_row(row, 0x282C34) end)
  end

  @spec status_bar(keyword()) :: [binary()]
  def status_bar(opts \\ []) do
    mode = Keyword.get(opts, :mode, "NORMAL")
    mode_bg = Keyword.get(opts, :mode_bg, 0x98C379)
    branch = Keyword.get(opts, :branch, "main")
    file = Keyword.get(opts, :file, "editor.ex")
    filetype = Keyword.get(opts, :filetype, "Elixir")
    pos = Keyword.get(opts, :pos, "1:1")

    [
      Protocol.encode_draw(23, 0, " #{mode} ", fg: 0x282C34, bg: mode_bg, bold: true),
      Protocol.encode_draw(23, String.length(mode) + 3, " #{branch} ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, String.length(mode) + String.length(branch) + 6, " #{file} ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 65, " #{filetype} ", fg: 0x61AFEF, bg: 0x3E4452),
      Protocol.encode_draw(23, 74, " #{pos} ", fg: 0xABB2BF, bg: 0x3E4452)
    ]
  end

  @spec editor_code_lines() :: [binary()]
  def editor_code_lines do
    [
      Protocol.encode_draw(0, 0, "defmodule", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(0, 10, "Minga.Editor", fg: 0xE5C07B, bg: 0x282C34, bold: true),
      Protocol.encode_draw(0, 23, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 0, "  alias Minga.Buffer", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(2, 0, "  alias Minga.Config", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(3, 0, "  alias Minga.Keymap", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(5, 0, "  @type", fg: 0xDA8548, bg: 0x282C34),
      Protocol.encode_draw(5, 8, "state :: %__MODULE__{}", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(7, 0, "  def", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(7, 5, " open", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(7, 10, "(path)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(7, 17, " do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(8, 0, "    {:ok, buffer} = Buffer.open(path)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(9, 0, "    layout = Layout.compute(state)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(10, 0, "    render(buffer, layout)", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(11, 0, "  end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(13, 0, "  def", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(13, 5, " close", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(13, 11, "(buffer)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(13, 20, " do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(14, 0, "    Buffer.save(buffer)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(15, 0, "    Buffer.close(buffer)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(16, 0, "  end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(18, 0, "  # Private helpers", fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_draw(19, 0, "  defp", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(19, 6, " render", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(19, 13, "(buffer, layout)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(19, 30, " do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(20, 0, "    # TODO: implement", fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_draw(21, 0, "  end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(22, 0, "end", fg: 0xC678DD, bg: 0x282C34)
    ]
  end
end

# Fixture 5: Picker / command palette overlay
# Shows an editor background with a centered picker popup. The picker has a search
# input at the top and six result items below, with one highlighted as selected.
picker_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    # Editor background content (dimmed under the overlay)
    FixtureHelpers.editor_code_lines() ++
    FixtureHelpers.status_bar(mode: "NORMAL", file: "editor.ex", pos: "8:5") ++
    [
      # Picker overlay: centered, 50 cols wide, starting at row 3
      # Top border / title
      Protocol.encode_draw(3, 15, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(3, 17, "Commands", fg: 0x5C6370, bg: 0x21252B, bold: true),
      # Search input row
      Protocol.encode_draw(4, 15, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(4, 16, "> ", fg: 0x61AFEF, bg: 0x21252B, bold: true),
      Protocol.encode_draw(4, 18, "open fi", fg: 0xABB2BF, bg: 0x21252B),
      # Separator
      Protocol.encode_draw(5, 15, String.duplicate("─", 50), fg: 0x3E4452, bg: 0x21252B),
      # Result items
      Protocol.encode_draw(6, 15, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x2B4A73),
      Protocol.encode_draw(6, 17, "Open File", fg: 0xDFDFDF, bg: 0x2B4A73, bold: true),
      Protocol.encode_draw(6, 52, "SPC f f", fg: 0x5C6370, bg: 0x2B4A73),
      Protocol.encode_draw(7, 15, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(7, 17, "Open File in Project", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(7, 52, "SPC p f", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(8, 15, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(8, 17, "Open File Tree", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(8, 52, "SPC o p", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(9, 15, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(9, 17, "Open Recent File", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(9, 52, "SPC f r", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(10, 15, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(10, 17, "Open Config File", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(10, 52, "SPC f P", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(11, 15, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(11, 17, "Open Finder Here", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(11, 52, "SPC o f", fg: 0x5C6370, bg: 0x21252B),
      # Bottom border with result count
      Protocol.encode_draw(12, 15, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(12, 17, "6/42 results", fg: 0x5C6370, bg: 0x21252B),
      # Cursor in the search input
      Protocol.encode_cursor(4, 25),
      Protocol.encode_cursor_shape(:beam),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("picker", picker_commands)

# Fixture 6: Minibuffer / command entry at the bottom of the screen
# Shows editor content with a minibuffer prompt at row 22 (just above the status bar)
# displaying a partial ":" command.
minibuffer_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    FixtureHelpers.editor_code_lines() ++
    [
      # Minibuffer at row 22 (above status bar at row 23)
      Protocol.encode_draw(22, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x1B1F27),
      Protocol.encode_draw(22, 0, ":", fg: 0x61AFEF, bg: 0x1B1F27, bold: true),
      Protocol.encode_draw(22, 1, "buffer-", fg: 0xABB2BF, bg: 0x1B1F27),
      # Status bar showing COMMAND mode
      Protocol.encode_draw(23, 0, " COMMAND ", fg: 0x282C34, bg: 0x61AFEF, bold: true),
      Protocol.encode_draw(23, 10, " main ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 17, " editor.ex ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 65, " Elixir ", fg: 0x61AFEF, bg: 0x3E4452),
      Protocol.encode_draw(23, 74, " 8:5 ", fg: 0xABB2BF, bg: 0x3E4452),
      # Cursor in the minibuffer after typed text
      Protocol.encode_cursor(22, 8),
      Protocol.encode_cursor_shape(:beam),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("minibuffer", minibuffer_commands)

# Fixture 7: Which-key popup showing keybinding groups
# Shows editor content with a which-key popup panel at the bottom displaying
# SPC-leader key groups.
which_key_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    FixtureHelpers.editor_code_lines() ++
    [
      # Which-key popup occupies rows 16-22 (above status bar)
      # Title row
      Protocol.encode_draw(16, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(16, 2, "SPC", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(16, 6, "Leader key bindings", fg: 0x5C6370, bg: 0x21252B),
      # Separator
      Protocol.encode_draw(17, 0, String.duplicate("─", 80), fg: 0x3E4452, bg: 0x21252B),
      # Key groups: three columns layout
      # Column 1 (col 2-26)
      Protocol.encode_draw(18, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(18, 2, "f", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(18, 4, "→ file", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(18, 28, "b", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(18, 30, "→ buffer", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(18, 54, "w", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(18, 56, "→ window", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(19, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(19, 2, "p", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(19, 4, "→ project", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(19, 28, "s", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(19, 30, "→ search", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(19, 54, "g", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(19, 56, "→ git", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(20, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(20, 2, "o", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(20, 4, "→ open", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(20, 28, "c", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(20, 30, "→ code", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(20, 54, "h", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(20, 56, "→ help", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(21, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(21, 2, "t", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(21, 4, "→ toggle", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(21, 28, "q", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(21, 30, "→ quit", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(21, 54, "a", fg: 0xC678DD, bg: 0x21252B, bold: true),
      Protocol.encode_draw(21, 56, "→ agent", fg: 0xABB2BF, bg: 0x21252B),
      # Bottom padding
      Protocol.encode_draw(22, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x21252B),
    ] ++
    FixtureHelpers.status_bar(mode: "NORMAL", file: "editor.ex", pos: "8:5") ++
    [
      Protocol.encode_cursor(7, 10),
      Protocol.encode_cursor_shape(:block),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("which_key", which_key_commands)

# Fixture 8: Search with active query and highlighted matches
# Shows editor content with a search bar at the bottom and highlighted matches
# in the content area.
search_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear(),
    # Editor content with highlighted search matches
    Protocol.encode_draw(0, 0, "defmodule", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(0, 10, "Minga.Editor", fg: 0xE5C07B, bg: 0x282C34, bold: true),
    Protocol.encode_draw(0, 23, "do", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(1, 0, "  alias Minga.Buffer", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(2, 0, "  alias Minga.Config", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(3, 0, "  alias Minga.Keymap", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(5, 0, "  @type", fg: 0xDA8548, bg: 0x282C34),
    Protocol.encode_draw(5, 8, "state :: %__MODULE__{}", fg: 0xABB2BF, bg: 0x282C34),
    # Line 7: def open(path) do -- "def" highlighted as current match
    Protocol.encode_draw(7, 0, "  ", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(7, 2, "def", fg: 0x282C34, bg: 0xE5C07B, bold: true),
    Protocol.encode_draw(7, 5, " open", fg: 0x61AFEF, bg: 0x282C34),
    Protocol.encode_draw(7, 10, "(path)", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(7, 17, " do", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(8, 0, "    {:ok, buffer} = Buffer.open(path)", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(9, 0, "    layout = Layout.compute(state)", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(10, 0, "    render(buffer, layout)", fg: 0x61AFEF, bg: 0x282C34),
    Protocol.encode_draw(11, 0, "  end", fg: 0xC678DD, bg: 0x282C34),
    # Line 13: def close(buffer) do -- "def" highlighted as secondary match
    Protocol.encode_draw(13, 0, "  ", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(13, 2, "def", fg: 0x282C34, bg: 0x5C6370),
    Protocol.encode_draw(13, 5, " close", fg: 0x61AFEF, bg: 0x282C34),
    Protocol.encode_draw(13, 11, "(buffer)", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(13, 20, " do", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(14, 0, "    Buffer.save(buffer)", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(15, 0, "    Buffer.close(buffer)", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(16, 0, "  end", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(18, 0, "  # Private helpers", fg: 0x5C6370, bg: 0x282C34),
    # Line 19: defp render -- "def" highlighted as secondary match
    Protocol.encode_draw(19, 0, "  ", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(19, 2, "def", fg: 0x282C34, bg: 0x5C6370),
    Protocol.encode_draw(19, 5, "p", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(19, 6, " render", fg: 0x61AFEF, bg: 0x282C34),
    Protocol.encode_draw(19, 13, "(buffer, layout)", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(19, 30, " do", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(20, 0, "    # TODO: implement", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(21, 0, "  end", fg: 0xC678DD, bg: 0x282C34),
    # Search bar at row 22
    Protocol.encode_draw(22, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x1B1F27),
    Protocol.encode_draw(22, 0, "/", fg: 0xE5C07B, bg: 0x1B1F27, bold: true),
    Protocol.encode_draw(22, 1, "def", fg: 0xABB2BF, bg: 0x1B1F27),
    Protocol.encode_draw(22, 60, " 1/3 matches ", fg: 0x5C6370, bg: 0x1B1F27),
    # Status bar
    Protocol.encode_draw(23, 0, " NORMAL ", fg: 0x282C34, bg: 0x98C379, bold: true),
    Protocol.encode_draw(23, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
    Protocol.encode_draw(23, 16, " editor.ex ", fg: 0xABB2BF, bg: 0x3E4452),
    Protocol.encode_draw(23, 65, " Elixir ", fg: 0x61AFEF, bg: 0x3E4452),
    Protocol.encode_draw(23, 74, " 8:3 ", fg: 0xABB2BF, bg: 0x3E4452),
    # Cursor on the current match
    Protocol.encode_cursor(7, 2),
    Protocol.encode_cursor_shape(:block),
    Protocol.encode_batch_end()
  ]

FixtureWriter.write_fixture("search", search_commands)

# Fixture 9: Diagnostics with gutter signs and underlined tokens
# Shows editor content with error/warning markers in a gutter column and
# colored underlines on problematic tokens using encode_draw_styled for
# curly underlines.
diagnostics_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear(),
    # Gutter + editor content
    # Row 0: clean line
    Protocol.encode_draw(0, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(0, 2, " 1", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(0, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(0, 7, "defmodule", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(0, 17, "MyApp.Worker", fg: 0xE5C07B, bg: 0x282C34, bold: true),
    Protocol.encode_draw(0, 30, "do", fg: 0xC678DD, bg: 0x282C34),
    # Row 1: clean line
    Protocol.encode_draw(1, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(1, 2, " 2", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(1, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(1, 7, "  use GenServer", fg: 0xC678DD, bg: 0x282C34),
    # Row 2: blank
    Protocol.encode_draw(2, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(2, 2, " 3", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(2, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    # Row 3: warning sign on line 4
    Protocol.encode_draw(3, 0, "⚠ ", fg: 0xE0AF68, bg: 0x282C34),
    Protocol.encode_draw(3, 2, " 4", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(3, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(3, 7, "  def", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(3, 12, " init", fg: 0x61AFEF, bg: 0x282C34),
    Protocol.encode_draw(3, 17, "(", fg: 0xABB2BF, bg: 0x282C34),
    # "opts" with warning underline
    Protocol.encode_draw_styled(3, 18, "opts", fg: 0xE0AF68, bg: 0x282C34, underline: true, underline_style: :curl, underline_color: 0xE0AF68),
    Protocol.encode_draw(3, 22, ")", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(3, 24, " do", fg: 0xC678DD, bg: 0x282C34),
    # Row 4: clean line
    Protocol.encode_draw(4, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(4, 2, " 5", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(4, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(4, 7, "    state = %{count: 0}", fg: 0xABB2BF, bg: 0x282C34),
    # Row 5: clean line
    Protocol.encode_draw(5, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(5, 2, " 6", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(5, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(5, 7, "    {:ok, state}", fg: 0xABB2BF, bg: 0x282C34),
    # Row 6: clean line
    Protocol.encode_draw(6, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(6, 2, " 7", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(6, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(6, 7, "  end", fg: 0xC678DD, bg: 0x282C34),
    # Row 7: blank
    Protocol.encode_draw(7, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(7, 2, " 8", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(7, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    # Row 8: error sign on line 9
    Protocol.encode_draw(8, 0, "✖ ", fg: 0xE06C75, bg: 0x282C34),
    Protocol.encode_draw(8, 2, " 9", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(8, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(8, 7, "  def", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(8, 12, " handle_call", fg: 0x61AFEF, bg: 0x282C34),
    Protocol.encode_draw(8, 24, "(", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(8, 25, ":get", fg: 0x98C379, bg: 0x282C34),
    Protocol.encode_draw(8, 29, ", _from, state)", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(8, 44, " do", fg: 0xC678DD, bg: 0x282C34),
    # Row 9: the error is on this line
    Protocol.encode_draw(9, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(9, 2, "10", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(9, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(9, 7, "    {:reply, ", fg: 0xABB2BF, bg: 0x282C34),
    # "state.counnt" with error underline (typo)
    Protocol.encode_draw(9, 19, "state.", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw_styled(9, 25, "counnt", fg: 0xE06C75, bg: 0x282C34, underline: true, underline_style: :curl, underline_color: 0xE06C75),
    Protocol.encode_draw(9, 31, ", state}", fg: 0xABB2BF, bg: 0x282C34),
    # Row 10: clean
    Protocol.encode_draw(10, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(10, 2, "11", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(10, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(10, 7, "  end", fg: 0xC678DD, bg: 0x282C34),
    # Row 11: blank
    Protocol.encode_draw(11, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(11, 2, "12", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(11, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    # Row 12: info sign
    Protocol.encode_draw(12, 0, "● ", fg: 0x61AFEF, bg: 0x282C34),
    Protocol.encode_draw(12, 2, "13", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(12, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(12, 7, "  def", fg: 0xC678DD, bg: 0x282C34),
    Protocol.encode_draw(12, 12, " handle_cast", fg: 0x61AFEF, bg: 0x282C34),
    Protocol.encode_draw(12, 24, "(:inc, state)", fg: 0xABB2BF, bg: 0x282C34),
    Protocol.encode_draw(12, 38, " do", fg: 0xC678DD, bg: 0x282C34),
    # Row 13
    Protocol.encode_draw(13, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(13, 2, "14", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(13, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(13, 7, "    {:noreply, %{state | count: state.count + 1}}", fg: 0xABB2BF, bg: 0x282C34),
    # Row 14
    Protocol.encode_draw(14, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(14, 2, "15", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(14, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(14, 7, "  end", fg: 0xC678DD, bg: 0x282C34),
    # Row 15
    Protocol.encode_draw(15, 0, "  ", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(15, 2, "16", fg: 0x5C6370, bg: 0x282C34),
    Protocol.encode_draw(15, 4, " │ ", fg: 0x3E4452, bg: 0x282C34),
    Protocol.encode_draw(15, 7, "end", fg: 0xC678DD, bg: 0x282C34),
    # Diagnostic summary at row 22
    Protocol.encode_draw(22, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x21252B),
    Protocol.encode_draw(22, 2, "✖ 1 error", fg: 0xE06C75, bg: 0x21252B),
    Protocol.encode_draw(22, 14, "  ⚠ 1 warning", fg: 0xE0AF68, bg: 0x21252B),
    Protocol.encode_draw(22, 30, "  ● 1 info", fg: 0x61AFEF, bg: 0x21252B),
    # Status bar
    Protocol.encode_draw(23, 0, " NORMAL ", fg: 0x282C34, bg: 0x98C379, bold: true),
    Protocol.encode_draw(23, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
    Protocol.encode_draw(23, 16, " worker.ex ", fg: 0xABB2BF, bg: 0x3E4452),
    Protocol.encode_draw(23, 57, " ✖ 1 ⚠ 1 ", fg: 0xE06C75, bg: 0x282C34),
    Protocol.encode_draw(23, 68, " Elixir ", fg: 0x61AFEF, bg: 0x3E4452),
    Protocol.encode_draw(23, 76, "9:25", fg: 0xABB2BF, bg: 0x3E4452),
    # Cursor on the error token
    Protocol.encode_cursor(9, 25),
    Protocol.encode_cursor_shape(:block),
    Protocol.encode_batch_end()
  ]

FixtureWriter.write_fixture("diagnostics", diagnostics_commands)

# Fixture 10: Split editor layout
# NOTE: Vertical splits are a V1 TUI feature. This fixture shows two editor panes
# side by side with a vertical separator, each with its own content and cursor.
split_editor_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    # Vertical separator at column 40
    Enum.map(0..22, fn row ->
      Protocol.encode_draw(row, 39, "│", fg: 0x3E4452, bg: 0x282C34)
    end) ++
    [
      # ── Left pane: editor.ex ──
      Protocol.encode_draw(0, 0, "defmodule", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(0, 10, "Minga.Editor", fg: 0xE5C07B, bg: 0x282C34, bold: true),
      Protocol.encode_draw(0, 23, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 0, "  alias Minga.Buffer", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(2, 0, "  alias Minga.Config", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(4, 0, "  def", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(4, 5, " open", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(4, 10, "(path)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(4, 17, " do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(5, 0, "    Buffer.open(path)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(6, 0, "  end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(7, 0, "end", fg: 0xC678DD, bg: 0x282C34),
      # ── Right pane: buffer.ex ──
      Protocol.encode_draw(0, 40, "defmodule", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(0, 50, "Minga.Buffer", fg: 0xE5C07B, bg: 0x282C34, bold: true),
      Protocol.encode_draw(0, 63, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 40, "  alias Minga.Buffer.Document", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(3, 40, "  @type", fg: 0xDA8548, bg: 0x282C34),
      Protocol.encode_draw(3, 48, "t :: %__MODULE__{}", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(5, 40, "  def", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(5, 45, " new", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(5, 49, "(content)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(5, 59, " do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(6, 40, "    Document.new(content)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(7, 40, "  end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(8, 40, "end", fg: 0xC678DD, bg: 0x282C34),
      # Status bar spans both panes
      Protocol.encode_draw(23, 0, " NORMAL ", fg: 0x282C34, bg: 0x98C379, bold: true),
      Protocol.encode_draw(23, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 16, " editor.ex ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 28, "│", fg: 0x3E4452, bg: 0x3E4452),
      Protocol.encode_draw(23, 30, " buffer.ex ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 65, " Elixir ", fg: 0x61AFEF, bg: 0x3E4452),
      Protocol.encode_draw(23, 74, " 5:10 ", fg: 0xABB2BF, bg: 0x3E4452),
      # Cursor in the active (left) pane
      Protocol.encode_cursor(4, 10),
      Protocol.encode_cursor_shape(:block),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("split_editor", split_editor_commands)

# Fixture 11: Agent panel
# NOTE: The TUI agent panel is planned for V1. This fixture shows an editor with
# a right-side agent chat panel containing a conversation with user message,
# thinking indicator, and assistant response.
agent_panel_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    # Editor pane (left, cols 0-44)
    [
      Protocol.encode_draw(0, 0, "defmodule", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(0, 10, "Minga.Editor", fg: 0xE5C07B, bg: 0x282C34, bold: true),
      Protocol.encode_draw(0, 23, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 0, "  alias Minga.Buffer", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(3, 0, "  def", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(3, 5, " open", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(3, 10, "(path)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(3, 17, " do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(4, 0, "    Buffer.open(path)", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(5, 0, "  end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(6, 0, "end", fg: 0xC678DD, bg: 0x282C34)
    ] ++
    # Vertical separator at column 45
    Enum.map(0..22, fn row ->
      Protocol.encode_draw(row, 45, "│", fg: 0x3E4452, bg: 0x282C34)
    end) ++
    # Agent panel background (right, cols 46-79)
    Enum.map(0..22, fn row ->
      Protocol.encode_draw(row, 46, String.duplicate(" ", 34), fg: 0xABB2BF, bg: 0x21252B)
    end) ++
    [
      # Panel title
      Protocol.encode_draw(0, 48, "Agent", fg: 0x61AFEF, bg: 0x21252B, bold: true),
      Protocol.encode_draw(0, 72, "claude", fg: 0x5C6370, bg: 0x21252B),
      # Separator
      Protocol.encode_draw(1, 46, String.duplicate("─", 34), fg: 0x3E4452, bg: 0x21252B),
      # User message
      Protocol.encode_draw(3, 48, "You:", fg: 0x98C379, bg: 0x21252B, bold: true),
      Protocol.encode_draw(4, 48, "Add a @spec to the open", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(5, 48, "function.", fg: 0xABB2BF, bg: 0x21252B),
      # Separator
      Protocol.encode_draw(7, 46, String.duplicate("─", 34), fg: 0x3E4452, bg: 0x21252B),
      # Assistant response
      Protocol.encode_draw(9, 48, "Assistant:", fg: 0x61AFEF, bg: 0x21252B, bold: true),
      Protocol.encode_draw(10, 48, "I'll add the typespec. The", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(11, 48, "function takes a path and", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(12, 48, "returns an ok/error tuple:", fg: 0xABB2BF, bg: 0x21252B),
      # Code block in the response
      Protocol.encode_draw(14, 48, "@spec open(String.t())", fg: 0x98C379, bg: 0x1B1F27),
      Protocol.encode_draw(15, 48, "  :: {:ok, t()}", fg: 0x98C379, bg: 0x1B1F27),
      Protocol.encode_draw(16, 48, "   | {:error, term()}", fg: 0x98C379, bg: 0x1B1F27),
      # Thinking indicator
      Protocol.encode_draw(18, 48, "Applying changes...", fg: 0xE5C07B, bg: 0x21252B),
      Protocol.encode_draw(18, 68, "⠋", fg: 0x61AFEF, bg: 0x21252B),
      # Input area at bottom of panel
      Protocol.encode_draw(21, 46, String.duplicate("─", 34), fg: 0x3E4452, bg: 0x21252B),
      Protocol.encode_draw(22, 46, String.duplicate(" ", 34), fg: 0xABB2BF, bg: 0x1B1F27),
      Protocol.encode_draw(22, 47, "> ", fg: 0x61AFEF, bg: 0x1B1F27, bold: true),
      Protocol.encode_draw(22, 49, "Type a message...", fg: 0x5C6370, bg: 0x1B1F27),
      # Status bar
      Protocol.encode_draw(23, 0, " NORMAL ", fg: 0x282C34, bg: 0x98C379, bold: true),
      Protocol.encode_draw(23, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 16, " editor.ex ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 28, "│", fg: 0x3E4452, bg: 0x3E4452),
      Protocol.encode_draw(23, 30, " Agent ", fg: 0x61AFEF, bg: 0x3E4452),
      Protocol.encode_draw(23, 65, " Elixir ", fg: 0x61AFEF, bg: 0x3E4452),
      Protocol.encode_draw(23, 74, " 4:5 ", fg: 0xABB2BF, bg: 0x3E4452),
      # Cursor in the editor pane
      Protocol.encode_cursor(3, 5),
      Protocol.encode_cursor_shape(:block),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("agent_panel", agent_panel_commands)

# Fixture 5: INSERT mode with beam cursor and completion popup
insert_mode_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    [
      Protocol.encode_draw(0, 0, "  1 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(1, 0, "  2 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(2, 0, "  3 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(3, 0, "  4 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(4, 0, "  5 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(5, 0, "  6 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(6, 0, "  7 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(7, 0, "  8 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(8, 0, "  9 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(9, 0, " 10 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(0, 4, "defmodule", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(0, 14, "Router", fg: 0xE5C07B, bg: 0x282C34, bold: true),
      Protocol.encode_draw(0, 21, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 4, "  use", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 10, "Plug.Router", fg: 0xE5C07B, bg: 0x282C34),
      Protocol.encode_draw(3, 4, "  plug", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(3, 11, ":match", fg: 0xDA8548, bg: 0x282C34),
      Protocol.encode_draw(4, 4, "  plug", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(4, 11, ":dis", fg: 0xDA8548, bg: 0x282C34),
      Protocol.encode_draw(6, 4, "  get", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(6, 10, " \"/hello\"", fg: 0x98C379, bg: 0x282C34),
      Protocol.encode_draw(6, 20, " do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(7, 4, "    send_resp", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(7, 17, "(conn, ", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(7, 24, "200", fg: 0xDA8548, bg: 0x282C34),
      Protocol.encode_draw(7, 27, ", ", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(7, 29, "\"world\"", fg: 0x98C379, bg: 0x282C34),
      Protocol.encode_draw(7, 36, ")", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(8, 4, "  end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(9, 4, "end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(5, 11, " :dispatch              Plug ", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(6, 11, " :discard               Plug ", fg: 0xDFDFDF, bg: 0x2257A0, bold: true),
      Protocol.encode_draw(7, 11, " :disconnect            Plug ", fg: 0xABB2BF, bg: 0x21252B),
      Protocol.encode_draw(22, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 0, " INSERT ", fg: 0x282C34, bg: 0x7DCFFF, bold: true),
      Protocol.encode_draw(22, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 16, " router.ex [+] ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 70, " 5:15 ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 0, String.duplicate(" ", 80), fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_cursor(4, 15),
      Protocol.encode_cursor_shape(:beam),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("insert_mode", insert_mode_commands)

# Fixture 6: VISUAL mode selection spanning multiple lines
visual_selection_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    [
      Protocol.encode_draw(0, 0, "  1 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(1, 0, "  2 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(2, 0, "  3 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(3, 0, "  4 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(4, 0, "  5 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(5, 0, "  6 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(6, 0, "  7 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(7, 0, "  8 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(0, 4, "defmodule", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(0, 14, "Counter", fg: 0xE5C07B, bg: 0x282C34, bold: true),
      Protocol.encode_draw(0, 22, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 4, "  use", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 10, "GenServer", fg: 0xE5C07B, bg: 0x282C34),
      Protocol.encode_draw(3, 4, "  def", fg: 0xC678DD, bg: 0x2B4A73),
      Protocol.encode_draw(3, 10, "start_link", fg: 0x61AFEF, bg: 0x2B4A73),
      Protocol.encode_draw(3, 20, "(", fg: 0xABB2BF, bg: 0x2B4A73),
      Protocol.encode_draw(3, 21, "init", fg: 0xE06C75, bg: 0x2B4A73),
      Protocol.encode_draw(3, 25, ")", fg: 0xABB2BF, bg: 0x2B4A73),
      Protocol.encode_draw(3, 27, " do", fg: 0xC678DD, bg: 0x2B4A73),
      Protocol.encode_draw(3, 30, String.duplicate(" ", 50), fg: 0xABB2BF, bg: 0x2B4A73),
      Protocol.encode_draw(4, 4, "    GenServer", fg: 0xE5C07B, bg: 0x2B4A73),
      Protocol.encode_draw(4, 17, ".", fg: 0xABB2BF, bg: 0x2B4A73),
      Protocol.encode_draw(4, 18, "start_link", fg: 0x61AFEF, bg: 0x2B4A73),
      Protocol.encode_draw(4, 28, "(", fg: 0xABB2BF, bg: 0x2B4A73),
      Protocol.encode_draw(4, 29, "__MODULE__", fg: 0xDA8548, bg: 0x2B4A73),
      Protocol.encode_draw(4, 39, ", init)", fg: 0xABB2BF, bg: 0x2B4A73),
      Protocol.encode_draw(4, 46, String.duplicate(" ", 34), fg: 0xABB2BF, bg: 0x2B4A73),
      Protocol.encode_draw(5, 4, "  end", fg: 0xC678DD, bg: 0x2B4A73),
      Protocol.encode_draw(5, 9, String.duplicate(" ", 71), fg: 0xABB2BF, bg: 0x2B4A73),
      Protocol.encode_draw(7, 4, "  def", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(7, 10, "init", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(7, 14, "(", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(7, 15, "state", fg: 0xE06C75, bg: 0x282C34),
      Protocol.encode_draw(7, 20, ")", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(7, 22, " do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(22, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 0, " VISUAL ", fg: 0x282C34, bg: 0xBB9AF7, bold: true),
      Protocol.encode_draw(22, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 16, " counter.ex ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 70, " 4:3 ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 0, "-- VISUAL -- 3 lines selected", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(23, 29, String.duplicate(" ", 51), fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_cursor(3, 4),
      Protocol.encode_cursor_shape(:block),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("visual_selection", visual_selection_commands)

# Fixture 7: Message bar with error feedback
message_bar_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    [
      Protocol.encode_draw(0, 0, "  1 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(1, 0, "  2 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(2, 0, "  3 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(3, 0, "  4 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(4, 0, "  5 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(5, 0, "  6 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(6, 0, "  7 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(0, 4, "defmodule", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(0, 14, "App", fg: 0xE5C07B, bg: 0x282C34, bold: true),
      Protocol.encode_draw(0, 18, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 4, "  def", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 10, "run", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(1, 14, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(2, 4, "    IO", fg: 0xE5C07B, bg: 0x282C34),
      Protocol.encode_draw(2, 10, ".", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(2, 11, "puts", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(2, 15, "(", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(2, 16, "\"hello\"", fg: 0x98C379, bg: 0x282C34),
      Protocol.encode_draw(2, 23, ")", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(3, 4, "  end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(4, 4, "end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(5, 4, "~", fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_draw(6, 4, "~", fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_draw(22, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 0, " NORMAL ", fg: 0x282C34, bg: 0x98C379, bold: true),
      Protocol.encode_draw(22, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 16, " app.ex ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 70, " 1:1 ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 0, "E42: No buffers were deleted", fg: 0xE06C75, bg: 0x282C34),
      Protocol.encode_draw(23, 28, String.duplicate(" ", 52), fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_cursor(0, 4),
      Protocol.encode_cursor_shape(:block),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("message_bar", message_bar_commands)

# Fixture 8: Message bar with info/yank feedback
message_bar_info_commands =
  [
    Protocol.encode_set_window_bg(0x282C34),
    Protocol.encode_clear()
  ] ++
    [
      Protocol.encode_draw(0, 0, "  1 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(1, 0, "  2 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(2, 0, "  3 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(3, 0, "  4 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(4, 0, "  5 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(5, 0, "  6 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(6, 0, "  7 ", fg: 0x5C6370, bg: 0x21252B),
      Protocol.encode_draw(0, 4, "defmodule", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(0, 14, "App", fg: 0xE5C07B, bg: 0x282C34, bold: true),
      Protocol.encode_draw(0, 18, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 4, "  def", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(1, 10, "run", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(1, 14, "do", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(2, 4, "    IO", fg: 0xE5C07B, bg: 0x282C34),
      Protocol.encode_draw(2, 10, ".", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(2, 11, "puts", fg: 0x61AFEF, bg: 0x282C34),
      Protocol.encode_draw(2, 15, "(", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(2, 16, "\"hello\"", fg: 0x98C379, bg: 0x282C34),
      Protocol.encode_draw(2, 23, ")", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(3, 4, "  end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(4, 4, "end", fg: 0xC678DD, bg: 0x282C34),
      Protocol.encode_draw(5, 4, "~", fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_draw(6, 4, "~", fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_draw(22, 0, String.duplicate(" ", 80), fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 0, " NORMAL ", fg: 0x282C34, bg: 0x98C379, bold: true),
      Protocol.encode_draw(22, 9, " main ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 16, " app.ex ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(22, 70, " 1:1 ", fg: 0xABB2BF, bg: 0x3E4452),
      Protocol.encode_draw(23, 0, "3 lines yanked", fg: 0xABB2BF, bg: 0x282C34),
      Protocol.encode_draw(23, 14, String.duplicate(" ", 66), fg: 0x5C6370, bg: 0x282C34),
      Protocol.encode_cursor(0, 4),
      Protocol.encode_cursor_shape(:block),
      Protocol.encode_batch_end()
    ]

FixtureWriter.write_fixture("message_bar_info", message_bar_info_commands)

IO.puts("\nAll fixtures generated successfully.")
