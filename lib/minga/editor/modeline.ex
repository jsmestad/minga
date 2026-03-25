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
  alias Minga.UI.Devicon
  alias Minga.UI.Face

  alias Minga.UI.Theme

  @typedoc "A clickable region: column range mapping to a command."
  @type click_region ::
          {col_start :: non_neg_integer(), col_end :: non_neg_integer(), command :: atom()}

  # Powerline separator characters
  @separator ""

  @typedoc "LSP connection status for the modeline indicator."
  @type lsp_status :: :ready | :initializing | :starting | :error | :none

  @typedoc "Parser availability status for the modeline indicator."
  @type parser_status :: :available | :unavailable | :restarting

  @typedoc "Git diff summary: {added, modified, deleted} line counts."
  @type git_diff_summary :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil

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
          optional(:agent_theme_colors) => Minga.UI.Theme.Agent.t() | nil,
          optional(:mode_override) => String.t() | nil,
          optional(:lsp_status) => lsp_status(),
          optional(:parser_status) => parser_status(),
          optional(:git_branch) => String.t() | nil,
          optional(:git_diff_summary) => git_diff_summary(),
          optional(:diagnostic_counts) =>
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
        }

  @doc """
  Renders the modeline at the given row using the provided data.

  Returns `{draw_commands, click_regions}` where click_regions is a list of
  `{col_start, col_end, command_atom}` tuples for mouse hit-testing.
  """
  @spec render(non_neg_integer(), pos_integer(), modeline_data(), Theme.t(), non_neg_integer()) ::
          {[DisplayList.draw()], [click_region()]}
  def render(row, cols, data, theme \\ Minga.UI.Theme.get!(:doom_one), col_off \\ 0) do
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

    {devicon, devicon_color} = Devicon.icon_and_color(data.filetype)
    filetype_label = filetype_label(data.filetype)

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
    lsp_segments = build_lsp_segments(data, bar_bg, ml)
    parser_segments = build_parser_segments(data, bar_bg, ml)
    git_segments = build_git_segments(data, bar_bg, theme)
    diagnostic_segments = build_diagnostic_segments(data, bar_bg, theme)

    # Segments are {text, fg, bg, opts, click_target}
    # click_target is an atom command or nil for non-clickable segments
    left_segments =
      [
        {mode_segment, mode_fg, mode_bg, [bold: true], nil},
        {@separator, mode_bg, info_bg, [], nil},
        {file_segment, info_fg, info_bg, [], :buffer_list},
        {@separator, info_bg, bar_bg, [], nil}
      ] ++
        git_segments ++
        Enum.map(agent_segments, fn {text, fg, bg, opts} -> {text, fg, bg, opts, nil} end)

    right_segments =
      diagnostic_segments ++
        parser_segments ++
        lsp_segments ++
        [
          {" #{devicon}", devicon_color, filetype_bg, [], nil},
          {" #{filetype_label} ", filetype_fg, filetype_bg, [], :filetype_menu},
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
        cmd = DisplayList.draw(row, col, text, Face.new([{:fg, fg}, {:bg, bg} | opts]))
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

  @doc """
  Returns the cursor shape for the given mode.

  Accepts either a bare mode atom or the full vim state map. When the
  vim state is passed, `pending_replace: true` in normal mode produces
  an underline cursor (matching Vim's `r` feedback).
  """
  @spec cursor_shape(Mode.mode() | Minga.Editor.VimState.t()) ::
          Minga.Port.Protocol.cursor_shape()
  def cursor_shape(%{mode: :normal, mode_state: %{pending_replace: true}}), do: :underline
  def cursor_shape(%{mode: mode}), do: cursor_shape(mode)
  def cursor_shape(:insert), do: :beam
  def cursor_shape(:search), do: :beam
  def cursor_shape(:command), do: :beam
  def cursor_shape(:eval), do: :beam
  def cursor_shape(:search_prompt), do: :beam
  def cursor_shape(:replace), do: :underline
  def cursor_shape(_mode), do: :block

  # Nerd Font branch icon (U+E0A0)
  @branch_icon "\uE0A0"

  @spec build_git_segments(modeline_data(), non_neg_integer(), Theme.t()) ::
          [{String.t(), non_neg_integer(), non_neg_integer(), keyword(), atom() | nil}]
  defp build_git_segments(data, bar_bg, theme) do
    branch = Map.get(data, :git_branch)
    summary = Map.get(data, :git_diff_summary)

    case branch do
      nil ->
        []

      "" ->
        []

      name ->
        # Branch name uses the modeline's info foreground (muted, theme-aware)
        branch_fg = theme.modeline.info_fg
        branch_segment = {" #{@branch_icon} #{name}", branch_fg, bar_bg, [], nil}

        # Diff stats: +added ~modified -deleted, using theme git colors
        diff_segments = build_diff_stat_segments(summary, bar_bg, theme.git)

        [branch_segment | diff_segments]
    end
  end

  @spec build_diff_stat_segments(
          {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil,
          non_neg_integer(),
          Theme.Git.t()
        ) :: [{String.t(), non_neg_integer(), non_neg_integer(), keyword(), atom() | nil}]
  defp build_diff_stat_segments(nil, _bar_bg, _git_theme), do: []
  defp build_diff_stat_segments({0, 0, 0}, _bar_bg, _git_theme), do: []

  defp build_diff_stat_segments({added, modified, deleted}, bar_bg, git_theme) do
    [
      {added, "+", git_theme.added_fg},
      {modified, "~", git_theme.modified_fg},
      {deleted, "-", git_theme.deleted_fg}
    ]
    |> Enum.filter(fn {count, _, _} -> count > 0 end)
    |> Enum.map(fn {count, prefix, color} -> {" #{prefix}#{count}", color, bar_bg, [], nil} end)
  end

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

  @spec build_lsp_segments(modeline_data(), non_neg_integer(), Theme.Modeline.t()) ::
          [{String.t(), non_neg_integer(), non_neg_integer(), keyword(), atom() | nil}]
  # Nerd Font diagnostic icons
  @diag_error_icon "\u{F057}"
  @diag_warning_icon "\u{F071}"
  @diag_info_icon "\u{F05A}"

  @spec build_diagnostic_segments(modeline_data(), non_neg_integer(), Theme.t()) ::
          [{String.t(), non_neg_integer(), non_neg_integer(), keyword(), atom() | nil}]
  defp build_diagnostic_segments(%{diagnostic_counts: nil}, _bar_bg, _theme), do: []
  defp build_diagnostic_segments(%{diagnostic_counts: {0, 0, 0, 0}}, _bar_bg, _theme), do: []

  defp build_diagnostic_segments(
         %{diagnostic_counts: {errors, warnings, info, _hints}},
         bar_bg,
         theme
       ) do
    gutter = theme.gutter
    segments = []

    segments =
      if errors > 0 do
        [
          {" #{@diag_error_icon} #{errors}", gutter.error_fg, bar_bg, [], :diagnostic_list}
          | segments
        ]
      else
        segments
      end

    segments =
      if warnings > 0 do
        [
          {" #{@diag_warning_icon} #{warnings}", gutter.warning_fg, bar_bg, [], :diagnostic_list}
          | segments
        ]
      else
        segments
      end

    segments =
      if info > 0 do
        [{" #{@diag_info_icon} #{info}", gutter.info_fg, bar_bg, [], :diagnostic_list} | segments]
      else
        segments
      end

    # Hints are intentionally omitted from the modeline (too noisy).
    # Reverse because we prepended.
    Enum.reverse(segments)
  end

  defp build_diagnostic_segments(_data, _bar_bg, _theme), do: []

  defp build_lsp_segments(data, bar_bg, ml) do
    case Map.get(data, :lsp_status) do
      :ready -> [{"●", ml.lsp_ready || 0x98BE65, bar_bg, [], :lsp_info}]
      :initializing -> [{"⟳", ml.lsp_initializing || 0xECBE7B, bar_bg, [bold: true], :lsp_info}]
      :starting -> [{"◯", ml.lsp_starting || 0x5B6268, bar_bg, [], :lsp_info}]
      :error -> [{"✗", ml.lsp_error || 0xFF6C6B, bar_bg, [bold: true], :lsp_info}]
      _ -> []
    end
  end

  @spec build_parser_segments(modeline_data(), non_neg_integer(), Theme.Modeline.t()) ::
          [{String.t(), non_neg_integer(), non_neg_integer(), keyword(), atom() | nil}]
  defp build_parser_segments(data, bar_bg, ml) do
    case Map.get(data, :parser_status) do
      :unavailable ->
        # Red warning: parser is down, highlighting disabled
        [{"🌳✗", ml.lsp_error || 0xFF6C6B, bar_bg, [bold: true], :parser_restart}]

      :restarting ->
        # Yellow: parser is restarting
        [{"🌳⟳", ml.lsp_initializing || 0xECBE7B, bar_bg, [bold: true], :parser_restart}]

      _ ->
        # :available or nil — normal state, show nothing
        []
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
  defp mode_badge(:tool_confirm, _state), do: "INSTALL"

  @spec filetype_label(atom()) :: String.t()
  defp filetype_label(filetype) do
    case Minga.Language.Registry.get(filetype) do
      %{label: label} when is_binary(label) -> label
      _ -> filetype |> Atom.to_string() |> String.capitalize()
    end
  end
end
