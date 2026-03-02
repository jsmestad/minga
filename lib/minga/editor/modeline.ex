defmodule Minga.Editor.Modeline do
  @moduledoc """
  Doom Emacs-style modeline rendering.

  Renders the colored status line at row N-2. Takes a data map and viewport
  width; returns a list of draw commands. Has no dependency on the GenServer
  or any mutable state — pure `data → commands` transformation.
  """

  alias Minga.Mode
  alias Minga.Port.Protocol

  # Doom Emacs color palette for mode indicators
  @mode_colors %{
    # black on blue
    normal: {0x000000, 0x51AFEF},
    # black on green
    insert: {0x000000, 0x98BE65},
    # black on magenta
    visual: {0x000000, 0xC678DD},
    # black on orange
    operator_pending: {0x000000, 0xDA8548},
    # black on yellow
    command: {0x000000, 0xECBE7B},
    # black on red/orange
    replace: {0x000000, 0xFF6C6B},
    # black on cyan
    search: {0x000000, 0x46D9FF}
  }

  # Powerline separator characters
  @separator ""

  @typedoc "Data for rendering the modeline."
  @type modeline_data :: %{
          mode: Mode.mode(),
          mode_state: Mode.state(),
          file_name: String.t(),
          filetype: atom(),
          dirty_marker: String.t(),
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer(),
          line_count: non_neg_integer(),
          buf_index: pos_integer(),
          buf_count: non_neg_integer()
        }

  @doc "Renders the modeline at the given row using the provided data."
  @spec render(non_neg_integer(), pos_integer(), modeline_data()) :: [binary()]
  def render(row, cols, data) do
    {mode_fg, mode_bg} = Map.get(@mode_colors, data.mode, {0x000000, 0x51AFEF})
    bar_fg = 0xBBC2CF
    bar_bg = 0x23272E
    info_fg = 0xBBC2CF
    info_bg = 0x3F444A

    # Build segments
    mode_segment = " #{mode_badge(data.mode, data.mode_state)} "
    buf_indicator = if data.buf_count > 1, do: " [#{data.buf_index}/#{data.buf_count}]", else: ""
    file_segment = " #{data.file_name}#{data.dirty_marker}#{buf_indicator} "
    filetype_segment = " #{filetype_label(data.filetype)} "

    percent =
      if data.line_count <= 1,
        do: "Top",
        else: "#{div(data.cursor_line * 100, max(data.line_count - 1, 1))}%%"

    pos_segment = " #{data.cursor_line + 1}:#{data.cursor_col + 1} "
    pct_segment = " #{percent} "

    # Build draw commands as a list of {text, fg, bg, opts} segments,
    # then lay them out left-to-right.
    filetype_fg = 0x98BE65
    filetype_bg = bar_bg

    left_segments = [
      {mode_segment, mode_fg, mode_bg, bold: true},
      {@separator, mode_bg, info_bg, []},
      {file_segment, info_fg, info_bg, []},
      {@separator, info_bg, bar_bg, []}
    ]

    right_segments = [
      {filetype_segment, filetype_fg, filetype_bg, []},
      {@separator, info_bg, bar_bg, []},
      {pos_segment, info_fg, info_bg, []},
      {@separator, mode_bg, info_bg, []},
      {pct_segment, mode_fg, mode_bg, bold: true}
    ]

    left_width =
      Enum.reduce(left_segments, 0, fn {text, _, _, _}, acc -> acc + String.length(text) end)

    right_width =
      Enum.reduce(right_segments, 0, fn {text, _, _, _}, acc -> acc + String.length(text) end)

    fill_width = max(0, cols - left_width - right_width)

    all_segments =
      left_segments ++
        [{String.duplicate(" ", fill_width), bar_fg, bar_bg, []}] ++
        right_segments

    {commands, _} =
      Enum.reduce(all_segments, {[], 0}, fn {text, fg, bg, opts}, {cmds, col} ->
        cmd = Protocol.encode_draw(row, col, text, [{:fg, fg}, {:bg, bg} | opts])
        {[cmd | cmds], col + String.length(text)}
      end)

    Enum.reverse(commands)
  end

  @doc "Returns the cursor shape atom for the given mode."
  @spec cursor_shape(Mode.mode()) :: Protocol.cursor_shape()
  def cursor_shape(:insert), do: :beam
  def cursor_shape(:search), do: :beam
  def cursor_shape(:replace), do: :underline
  def cursor_shape(_mode), do: :block

  @spec mode_badge(Mode.mode(), Mode.state()) :: String.t()
  defp mode_badge(:visual, %Minga.Mode.VisualState{visual_type: :line}), do: "V-LINE"
  defp mode_badge(:normal, _state), do: "NORMAL"
  defp mode_badge(:insert, _state), do: "INSERT"
  defp mode_badge(:visual, _state), do: "VISUAL"
  defp mode_badge(:operator_pending, _state), do: "OPERATOR"
  defp mode_badge(:command, _state), do: "COMMAND"
  defp mode_badge(:replace, _state), do: "REPLACE"
  defp mode_badge(:search, _state), do: "SEARCH"
  defp mode_badge(:search_prompt, _state), do: "SEARCH"
  defp mode_badge(:substitute_confirm, _state), do: "SUBSTITUTE"

  @spec filetype_label(atom()) :: String.t()
  defp filetype_label(:text), do: "Text"
  defp filetype_label(:elixir), do: "Elixir"
  defp filetype_label(:erlang), do: "Erlang"
  defp filetype_label(:heex), do: "HEEx"
  defp filetype_label(:ruby), do: "Ruby"
  defp filetype_label(:javascript), do: "JavaScript"
  defp filetype_label(:typescript), do: "TypeScript"
  defp filetype_label(:javascript_react), do: "JSX"
  defp filetype_label(:typescript_react), do: "TSX"
  defp filetype_label(:go), do: "Go"
  defp filetype_label(:rust), do: "Rust"
  defp filetype_label(:zig), do: "Zig"
  defp filetype_label(:c), do: "C"
  defp filetype_label(:cpp), do: "C++"
  defp filetype_label(:lua), do: "Lua"
  defp filetype_label(:python), do: "Python"
  defp filetype_label(:bash), do: "Shell"
  defp filetype_label(:html), do: "HTML"
  defp filetype_label(:css), do: "CSS"
  defp filetype_label(:json), do: "JSON"
  defp filetype_label(:yaml), do: "YAML"
  defp filetype_label(:toml), do: "TOML"
  defp filetype_label(:markdown), do: "Markdown"
  defp filetype_label(:sql), do: "SQL"
  defp filetype_label(:graphql), do: "GraphQL"
  defp filetype_label(:kotlin), do: "Kotlin"
  defp filetype_label(:gleam), do: "Gleam"
  defp filetype_label(:dockerfile), do: "Dockerfile"
  defp filetype_label(:make), do: "Makefile"
  defp filetype_label(:emacs_lisp), do: "Emacs Lisp"
  defp filetype_label(:lfe), do: "LFE"
  defp filetype_label(:nix), do: "Nix"
  defp filetype_label(:java), do: "Java"
  defp filetype_label(:swift), do: "Swift"
  defp filetype_label(:fish), do: "Fish"
  defp filetype_label(other), do: other |> Atom.to_string() |> String.capitalize()
end
