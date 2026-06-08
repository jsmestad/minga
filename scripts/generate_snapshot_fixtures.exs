#!/usr/bin/env elixir
# Generates the `full_editor.bin` wire-format regression fixture.
#
# This is the one surviving snapshot fixture after the cell-grid render path
# (and its PNG rasterizer) was removed. It now records a SEMANTIC frame: the
# exact protocol command stream that `Minga.Frontend.Adapter.GUI.encode/2`
# produces for a representative full-editor render model (a buffer window with
# highlight spans, plus theme, file tree, tab bar, and status bar chrome).
#
# The fixture is consumed by `test/minga_editor/full_editor_fixture_test.exs`,
# which uses it as a guard against accidental wire-format / encoder drift.
#
# Each command is length-prefixed as `<<byte_size(cmd)::32, cmd::binary>>` and
# the commands are concatenated. The curated replay order is:
#
#   set_window_bg :: metal_commands :: chrome_commands :: batch_end
#
# so the first packet is always `set_window_bg` and the last is `batch_end`.
#
# Usage: mix run scripts/generate_snapshot_fixtures.exs

alias Minga.Frontend.Adapter.GUI
alias Minga.RenderModel
alias Minga.RenderModel.Cursor
alias Minga.RenderModel.UI
alias Minga.RenderModel.UI.FileTree
alias Minga.RenderModel.UI.StatusBar
alias Minga.RenderModel.UI.TabBar
alias Minga.RenderModel.UI.Theme
alias Minga.RenderModel.Window
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
    IO.puts("Generated: #{path} (#{length(commands)} commands, #{IO.iodata_length(data)} bytes)")
  end
end

defmodule SnapshotModel do
  @moduledoc false

  @window_bg 0x282C34

  # Doom One inspired palette used for the highlight spans below.
  @fg_default 0xABB2BF
  @fg_keyword 0xC678DD
  @fg_type 0xE5C07B
  @fg_func 0x61AFEF
  @fg_string 0x98C379
  @fg_comment 0x5C6370
  @fg_punct 0xABB2BF

  # Span attribute bits mirror Minga.RenderModel.Window.Span.encode_attrs/1.
  @attr_none 0
  @attr_bold 1

  @spec window_bg() :: non_neg_integer()
  def window_bg, do: @window_bg

  @doc "Builds a representative full-editor render model with non-trivial content."
  @spec build() :: RenderModel.t()
  def build do
    window = build_window()
    ui = build_ui()
    cursor = Cursor.new(2, 6, :beam)

    RenderModel.new([window], ui, cursor, "Minga - editor.ex", @window_bg)
  end

  @spec build_window() :: Window.t()
  defp build_window do
    rows = [
      code_row(0, "defmodule Minga.Editor do", [
        span(0, 9, @fg_keyword, @window_bg, @attr_none),
        span(10, 22, @fg_type, @window_bg, @attr_bold),
        span(23, 25, @fg_keyword, @window_bg, @attr_none)
      ]),
      code_row(1, "  @moduledoc \"The editor core\"", [
        span(2, 12, 0xDA8548, @window_bg, @attr_none),
        span(13, 30, @fg_string, @window_bg, @attr_none)
      ]),
      code_row(2, "  def open(path) do", [
        span(2, 5, @fg_keyword, @window_bg, @attr_none),
        span(6, 10, @fg_func, @window_bg, @attr_none),
        span(10, 11, @fg_punct, @window_bg, @attr_none),
        span(11, 15, 0xE06C75, @window_bg, @attr_none),
        span(15, 16, @fg_punct, @window_bg, @attr_none),
        span(17, 19, @fg_keyword, @window_bg, @attr_none)
      ]),
      code_row(3, "    {:ok, Buffer.open(path)}", [
        span(4, 28, @fg_default, @window_bg, @attr_none)
      ]),
      code_row(4, "  end", [
        span(2, 5, @fg_keyword, @window_bg, @attr_none)
      ]),
      code_row(5, "  # render entry point", [
        span(2, 22, @fg_comment, @window_bg, @attr_none)
      ]),
      code_row(6, "end", [
        span(0, 3, @fg_keyword, @window_bg, @attr_none)
      ])
    ]

    %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 24, 56, 22},
      rows: rows,
      cursor_row: 2,
      cursor_col: 6,
      cursor_shape: :beam,
      content_epoch: 1,
      full_refresh: true
    }
  end

  @spec code_row(non_neg_integer(), String.t(), [Window.Span.t()]) :: Window.Row.t()
  defp code_row(buf_line, text, spans) do
    %Window.Row{
      row_id: Window.Row.stable_id(:normal, buf_line),
      row_type: :normal,
      buf_line: buf_line,
      text: text,
      spans: spans,
      content_hash: Window.Row.compute_hash(text, spans)
    }
  end

  @spec span(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Window.Span.t()
  defp span(start_col, end_col, fg, bg, attrs) do
    %Window.Span{start_col: start_col, end_col: end_col, fg: fg, bg: bg, attrs: attrs}
  end

  @spec build_ui() :: UI.t()
  defp build_ui do
    %UI{
      theme: %Theme{
        name: :doom_one,
        color_slots: [
          {0x01, @fg_default},
          {0x02, @fg_keyword},
          {0x03, @fg_type},
          {0x04, @fg_func},
          {0x05, @fg_string},
          {0x06, @fg_comment}
        ]
      },
      file_tree: %FileTree{
        status: :ready,
        root_path: "/workspace",
        tree_width: 24,
        focused?: false,
        selected_id: "lib/minga/editor.ex",
        rows: [
          tree_row("lib", "lib", 0, %FileTree.Flags{directory?: true, expanded?: true}),
          tree_row("lib/minga", "minga", 1, %FileTree.Flags{directory?: true, expanded?: true}),
          tree_row("lib/minga/editor.ex", "editor.ex", 2, %FileTree.Flags{
            active?: true,
            dirty?: true
          }),
          tree_row("lib/minga/buffer.ex", "buffer.ex", 2, %FileTree.Flags{last_child?: true})
        ]
      },
      tab_bar: %TabBar{
        visible?: true,
        active_tab_id: 1,
        tabs: [
          %TabBar.Tab{id: 1, workspace_id: 1, label: "editor.ex", icon: "ex", dirty?: true},
          %TabBar.Tab{id: 2, workspace_id: 1, label: "buffer.ex", icon: "ex"}
        ]
      },
      status_bar: %StatusBar{
        content_kind: :buffer,
        data: %StatusBar.Data{
          mode: :normal,
          dirty?: true,
          file: %StatusBar.File{name: "editor.ex", filetype: :elixir},
          cursor: %StatusBar.Cursor{line: 3, col: 7, line_count: 7},
          git: %StatusBar.Git{branch: "main"}
        }
      }
    }
  end

  @spec tree_row(String.t(), String.t(), non_neg_integer(), FileTree.Flags.t()) ::
          FileTree.Row.t()
  defp tree_row(id, name, depth, flags) do
    %FileTree.Row{
      id: id,
      path: id,
      name: name,
      icon: if(flags.directory?, do: "folder", else: "file"),
      flags: flags,
      depth: depth,
      guides: List.duplicate(false, depth)
    }
  end
end

model = SnapshotModel.build()
encoded = GUI.encode(model, GUI.Caches.new())

commands =
  [Protocol.encode_set_window_bg(SnapshotModel.window_bg())] ++
    encoded.metal_commands ++
    encoded.chrome_commands ++
    [Protocol.encode_batch_end()]

FixtureWriter.write_fixture("full_editor", commands)
