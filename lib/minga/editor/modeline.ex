defmodule Minga.Editor.Modeline do
  @moduledoc """
  Doom Emacs-style modeline rendering.

  Renders the colored status line at row N-2. Takes a data map and viewport
  width; returns a list of draw tuples and a list of clickable regions. Has
  no dependency on the GenServer or any mutable state, just a pure
  `data → {draws, click_regions}` transformation.

  Click regions are `{col_start, col_end, command}` tuples attached to
  segments at render time, matching how Doom Emacs embeds `local-map` text
  properties and Neovim embeds `%@ClickHandler@` markers. The mouse handler
  looks up the command for a clicked column without reverse-engineering the
  layout.
  """

  alias Minga.Buffer.Unicode
  alias Minga.Editor.DisplayList
  alias Minga.Mode

  alias Minga.Theme

  @typedoc "A clickable region: column range mapping to a command."
  @type click_region ::
          {col_start :: non_neg_integer(), col_end :: non_neg_integer(), command :: atom()}

  # Powerline separator characters
  @separator ""

  @typedoc "Data for rendering the modeline."
  @type modeline_data :: %{
          :mode => Mode.mode(),
          :mode_state => Mode.state() | nil,
          :file_name => String.t(),
          :filetype => atom(),
          :dirty_marker => String.t(),
          :cursor_line => non_neg_integer(),
          :cursor_col => non_neg_integer(),
          :line_count => non_neg_integer(),
          :buf_index => pos_integer(),
          :buf_count => non_neg_integer(),
          :macro_recording => {true, String.t()} | false,
          optional(:agent_status) => Minga.Editor.State.Agent.status(),
          optional(:agent_theme_colors) => Minga.Theme.Agent.t() | nil,
          optional(:mode_override) => String.t() | nil
        }

  @doc """
  Renders the modeline at the given row using the provided data.

  Returns `{draw_commands, click_regions}` where click_regions is a list of
  `{col_start, col_end, command_atom}` tuples for mouse hit-testing.
  """
  @spec render(non_neg_integer(), pos_integer(), modeline_data(), Theme.t(), non_neg_integer()) ::
          {[DisplayList.draw()], [click_region()]}
  def render(row, cols, data, theme \\ Minga.Theme.get!(:doom_one), col_off \\ 0) do
    ml = theme.modeline

    {mode_fg, mode_bg} =
      Map.get(ml.mode_colors, data.mode, {0x000000, ml.mode_colors.normal |> elem(1)})

    bar_fg = ml.bar_fg
    bar_bg = ml.bar_bg
    info_fg = ml.info_fg
    info_bg = ml.info_bg

    # Build segments
    badge = data[:mode_override] || mode_badge(data.mode, data.mode_state)
    mode_segment = " #{badge} "
    buf_indicator = if data.buf_count > 1, do: " [#{data.buf_index}/#{data.buf_count}]", else: ""

    macro_indicator =
      case Map.get(data, :macro_recording, false) do
        {true, reg} -> " recording @#{reg}"
        _ -> ""
      end

    file_segment = " #{data.file_name}#{data.dirty_marker}#{buf_indicator}#{macro_indicator} "
    filetype_segment = " #{filetype_label(data.filetype)} "

    percent =
      if data.line_count <= 1,
        do: "Top",
        else: "#{div(data.cursor_line * 100, max(data.line_count - 1, 1))}%%"

    pos_segment = " #{data.cursor_line + 1}:#{data.cursor_col + 1} "
    pct_segment = " #{percent} "

    # Build draw commands as a list of {text, fg, bg, opts} segments,
    # then lay them out left-to-right.
    filetype_fg = ml.filetype_fg
    filetype_bg = bar_bg

    agent_segments = build_agent_segments(data, bar_bg)

    # Segments are {text, fg, bg, opts, click_target}
    # click_target is an atom command or nil for non-clickable segments
    left_segments =
      [
        {mode_segment, mode_fg, mode_bg, [bold: true], nil},
        {@separator, mode_bg, info_bg, [], nil},
        {file_segment, info_fg, info_bg, [], :buffer_list},
        {@separator, info_bg, bar_bg, [], nil}
      ] ++ Enum.map(agent_segments, fn {text, fg, bg, opts} -> {text, fg, bg, opts, nil} end)

    right_segments = [
      {filetype_segment, filetype_fg, filetype_bg, [], nil},
      {@separator, info_bg, bar_bg, [], nil},
      {pos_segment, info_fg, info_bg, [], nil},
      {@separator, mode_bg, info_bg, [], nil},
      {pct_segment, mode_fg, mode_bg, [bold: true], nil}
    ]

    left_width =
      Enum.reduce(left_segments, 0, fn {text, _, _, _, _}, acc ->
        acc + Unicode.display_width(text)
      end)

    right_width =
      Enum.reduce(right_segments, 0, fn {text, _, _, _, _}, acc ->
        acc + Unicode.display_width(text)
      end)

    fill_width = max(0, cols - left_width - right_width)

    all_segments =
      left_segments ++
        [{String.duplicate(" ", fill_width), bar_fg, bar_bg, [], nil}] ++
        right_segments

    {commands, click_regions, _} =
      Enum.reduce(all_segments, {[], [], col_off}, fn {text, fg, bg, opts, target},
                                                      {cmds, regions, col} ->
        cmd = DisplayList.draw(row, col, text, [{:fg, fg}, {:bg, bg} | opts])
        width = Unicode.display_width(text)
        next_col = col + width

        new_regions =
          case target do
            nil -> regions
            command -> [{col, next_col, command} | regions]
          end

        {[cmd | cmds], new_regions, next_col}
      end)

    {Enum.reverse(commands), Enum.reverse(click_regions)}
  end

  @doc "Returns the cursor shape atom for the given mode."
  @spec cursor_shape(Mode.mode()) :: Minga.Port.Protocol.cursor_shape()
  def cursor_shape(:insert), do: :beam
  def cursor_shape(:search), do: :beam
  def cursor_shape(:replace), do: :underline
  def cursor_shape(_mode), do: :block

  @spec build_agent_segments(modeline_data(), non_neg_integer()) ::
          [{String.t(), non_neg_integer(), non_neg_integer(), keyword()}]
  defp build_agent_segments(data, bar_bg) do
    status = Map.get(data, :agent_status)
    colors = Map.get(data, :agent_theme_colors)

    case {status, colors} do
      {nil, _} -> []
      {:idle, c} -> [{" ◯ ", c.status_idle, bar_bg, []}]
      {:thinking, c} -> [{" ⟳ ", c.status_thinking, bar_bg, bold: true}]
      {:tool_executing, c} -> [{" ⚡ ", c.status_tool, bar_bg, bold: true}]
      {:error, c} -> [{" ✗ ", c.status_error, bar_bg, bold: true}]
      _ -> []
    end
  end

  @spec mode_badge(Mode.mode(), Mode.state()) :: String.t()
  defp mode_badge(:visual, %Minga.Mode.VisualState{visual_type: :line}), do: "V-LINE"
  defp mode_badge(:normal, _state), do: "NORMAL"
  defp mode_badge(:insert, _state), do: "INSERT"
  defp mode_badge(:visual, _state), do: "VISUAL"
  defp mode_badge(:operator_pending, _state), do: "NORMAL"
  defp mode_badge(:command, _state), do: "COMMAND"
  defp mode_badge(:replace, _state), do: "REPLACE"
  defp mode_badge(:search, _state), do: "SEARCH"
  defp mode_badge(:search_prompt, _state), do: "SEARCH"
  defp mode_badge(:substitute_confirm, _state), do: "SUBSTITUTE"
  defp mode_badge(:extension_confirm, _state), do: "UPDATE"

  @spec filetype_label(atom()) :: String.t()
  defp filetype_label(filetype) do
    case Minga.Language.Registry.get(filetype) do
      %{label: label} when is_binary(label) -> label
      _ -> filetype |> Atom.to_string() |> String.capitalize()
    end
  end
end
