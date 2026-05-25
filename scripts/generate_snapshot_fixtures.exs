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

IO.puts("\nAll fixtures generated successfully.")
