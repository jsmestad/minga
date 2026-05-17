defmodule MingaEditor.Shell.Traditional.Modeline do
  @moduledoc """
  Doom Emacs-style modeline rendering.

  Renders the colored status line at row N-2. Takes a data map and viewport width; returns a list of draw tuples and a list of clickable regions. Segment selection comes from `Minga.Config.Options`, and custom segments come from `Minga.Config.ModelineSegments`.

  Click regions are `{col_start, col_end, command}` tuples attached to segments at render time, matching how Doom Emacs embeds `local-map` text properties and Neovim embeds `%@ClickHandler@` markers. The mouse handler looks up the command for a clicked column without reverse-engineering the layout.
  """

  alias Minga.Config.ModelineSegment
  alias Minga.Config.ModelineSegments
  alias Minga.Core.Face
  alias Minga.Core.Unicode
  alias Minga.Mode
  alias MingaEditor.DisplayList
  alias MingaEditor.UI.Devicon
  alias MingaEditor.UI.Theme

  @typedoc "A clickable region: column range mapping to a command."
  @type click_region ::
          {col_start :: non_neg_integer(), col_end :: non_neg_integer(), command :: atom()}

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
          optional(:agent_status) => MingaEditor.State.Agent.status(),
          optional(:agent_theme_colors) => MingaEditor.UI.Theme.Agent.t() | nil,
          optional(:mode_override) => String.t() | nil,
          optional(:lsp_status) => lsp_status(),
          optional(:parser_status) => parser_status(),
          optional(:git_branch) => String.t() | nil,
          optional(:git_diff_summary) => git_diff_summary(),
          optional(:diagnostic_counts) =>
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil,
          optional(:indent_type) => :spaces | :tabs,
          optional(:indent_size) => pos_integer(),
          optional(:selection_info) =>
            {:chars, non_neg_integer()} | {:lines, pos_integer()} | nil,
          optional(:background_subagent_count) => non_neg_integer(),
          optional(:active_background_subagent_label) => String.t() | nil
        }

  @type separator_style :: :powerline | :round | :slant | :none
  @type render_segment :: ModelineSegment.render_segment()
  @type gui_segment ::
          {atom(), String.t(), non_neg_integer(), non_neg_integer(), keyword(), atom() | nil}
  @type segment_group :: %{name: atom(), priority: integer(), segments: [render_segment()]}
  @type gui_segments :: %{left: [gui_segment()], right: [gui_segment()]}
  @type context :: %{
          data: modeline_data(),
          theme: Theme.t(),
          bar_bg: non_neg_integer(),
          bar_fg: non_neg_integer(),
          info_bg: non_neg_integer(),
          info_fg: non_neg_integer(),
          mode_bg: non_neg_integer(),
          mode_fg: non_neg_integer()
        }

  @segment_priorities %{
    mode: 100,
    filename: 90,
    git: 60,
    agent: 50,
    background_agent: 45,
    diagnostics: 65,
    parser: 30,
    lsp: 70,
    filetype: 80,
    position: 85,
    percent: 40,
    indent: 35,
    selection: 75
  }

  @separator_chars %{
    powerline: {"", ""},
    round: {"", ""},
    slant: {"", ""},
    none: {"", ""}
  }

  @boolean_segment_attrs [:bold, :italic, :underline, :strikethrough, :reverse]
  @underline_styles [:line, :curl, :dashed, :dotted, :double]
  @font_weights [:thin, :light, :regular, :medium, :semibold, :bold, :heavy, :black]
  @font_slants [:roman, :italic, :oblique]

  # Nerd Font branch icon (U+E0A0)
  @branch_icon "\uE0A0"

  # Nerd Font diagnostic icons
  @diag_error_icon "\u{F057}"
  @diag_warning_icon "\u{F071}"
  @diag_info_icon "\u{F05A}"

  @doc "Returns the built-in modeline segment names."
  @spec built_in_segments() :: [atom()]
  def built_in_segments, do: ModelineSegments.reserved_names()

  @doc """
  Renders the modeline at the given row using the provided data.

  Returns `{draw_commands, click_regions}` where click_regions is a list of `{col_start, col_end, command_atom}` tuples for mouse hit-testing.
  """
  @spec render(non_neg_integer(), pos_integer(), modeline_data(), Theme.t(), non_neg_integer()) ::
          {[DisplayList.draw()], [click_region()]}
  def render(row, cols, data, theme \\ MingaEditor.UI.Theme.get!(:doom_one), col_off \\ 0) do
    ctx = context(data, theme)
    separator_style = Minga.Config.get(:modeline_separator)
    {left_names, right_names} = configured_segment_names()
    left_groups = build_segment_groups(left_names, ctx)
    right_groups = build_segment_groups(right_names, ctx)

    {left_groups, right_groups} =
      fit_segment_groups(left_groups, right_groups, cols, separator_style, ctx.bar_bg)

    left_segments = left_segments(left_groups, separator_style, ctx.bar_bg)
    right_segments = right_segments(right_groups, separator_style, ctx.bar_bg)
    left_width = segments_width(left_segments)
    right_width = segments_width(right_segments)
    fill_width = max(0, cols - left_width - right_width)

    all_segments =
      left_segments ++
        [{String.duplicate(" ", fill_width), ctx.bar_fg, ctx.bar_bg, [], nil}] ++ right_segments

    emit_segments(row, col_off, all_segments)
  end

  @doc "Returns configured modeline segments for native GUI status bars."
  @spec gui_segments(modeline_data(), Theme.t()) :: gui_segments()
  @spec gui_segments(modeline_data(), Theme.t(), ModelineSegments.table()) :: gui_segments()
  def gui_segments(
        data,
        theme \\ MingaEditor.UI.Theme.get!(:doom_one),
        modeline_segments_table \\ ModelineSegments
      ) do
    ctx = context(data, theme)
    {left_names, right_names} = configured_segment_names(modeline_segments_table)
    left_groups = build_segment_groups(left_names, ctx, modeline_segments_table)
    right_groups = build_segment_groups(right_names, ctx, modeline_segments_table)

    %{
      left: gui_segments_from_groups(left_groups),
      right: gui_segments_from_groups(right_groups)
    }
  end

  @doc """
  Returns the cursor shape for the given mode.

  Accepts either a bare mode atom or the full vim state map. When the vim state is passed, `pending: :replace` in normal mode produces an underline cursor (matching Vim's `r` feedback).
  """
  @spec cursor_shape(Mode.mode() | MingaEditor.VimState.t()) ::
          MingaEditor.Frontend.Protocol.cursor_shape()
  def cursor_shape(%{mode: :normal, mode_state: %{pending: :replace}}), do: :underline
  def cursor_shape(%{mode: mode}), do: cursor_shape(mode)
  def cursor_shape(:insert), do: :beam
  def cursor_shape(:search), do: :beam
  def cursor_shape(:command), do: :beam
  def cursor_shape(:eval), do: :beam
  def cursor_shape(:search_prompt), do: :beam
  def cursor_shape(:replace), do: :underline
  def cursor_shape(_mode), do: :block

  @spec context(modeline_data(), Theme.t()) :: context()
  defp context(data, theme) do
    ml = theme.modeline

    {mode_fg, mode_bg} =
      case Map.fetch(ml.mode_colors, data.mode) do
        {:ok, colors} -> colors
        :error -> {0x000000, elem(ml.mode_colors.normal, 1)}
      end

    %{
      data: data,
      theme: theme,
      bar_bg: ml.bar_bg,
      bar_fg: ml.bar_fg,
      info_bg: ml.info_bg,
      info_fg: ml.info_fg,
      mode_bg: mode_bg,
      mode_fg: mode_fg
    }
  end

  @spec configured_segment_names() :: {[atom()], [atom()]}
  @spec configured_segment_names(ModelineSegments.table()) :: {[atom()], [atom()]}
  defp configured_segment_names(modeline_segments_table \\ ModelineSegments) do
    left = Minga.Config.get(:modeline_left_segments)
    right = Minga.Config.get(:modeline_right_segments)
    configured = MapSet.new(left ++ right)

    left_defaults =
      modeline_segments_table
      |> ModelineSegments.names_for_side(:left)
      |> Enum.reject(&MapSet.member?(configured, &1))

    right_defaults =
      modeline_segments_table
      |> ModelineSegments.names_for_side(:right)
      |> Enum.reject(&MapSet.member?(configured, &1))

    {left ++ left_defaults, right ++ right_defaults}
  end

  @spec build_segment_groups([atom()], context()) :: [segment_group()]
  @spec build_segment_groups([atom()], context(), ModelineSegments.table()) :: [segment_group()]
  defp build_segment_groups(names, ctx, modeline_segments_table \\ ModelineSegments) do
    names
    |> Enum.map(&build_segment_group(&1, ctx, modeline_segments_table))
    |> Enum.reject(&is_nil/1)
  end

  @spec build_segment_group(atom(), context(), ModelineSegments.table()) :: segment_group() | nil
  defp build_segment_group(name, ctx, modeline_segments_table) do
    case builtin_priority(name) do
      {:ok, priority} -> group_from_segments(name, priority, render_builtin(name, ctx))
      :error -> build_custom_segment_group(name, ctx, modeline_segments_table)
    end
  end

  @spec build_custom_segment_group(atom(), context(), ModelineSegments.table()) ::
          segment_group() | nil
  defp build_custom_segment_group(name, ctx, modeline_segments_table) do
    case ModelineSegments.lookup(modeline_segments_table, name) do
      %ModelineSegment{} = segment ->
        group_from_segments(name, segment.priority, render_custom(segment, ctx))

      nil ->
        unknown_segment(name, modeline_segments_table)
    end
  end

  @spec unknown_segment(atom(), ModelineSegments.table()) :: nil
  defp unknown_segment(name, modeline_segments_table) do
    ModelineSegments.warn_once(
      modeline_segments_table,
      {:unknown_segment, name},
      "Unknown modeline segment #{inspect(name)} ignored"
    )

    nil
  end

  @spec builtin_priority(atom()) :: {:ok, integer()} | :error
  defp builtin_priority(name), do: Map.fetch(@segment_priorities, name)

  @spec group_from_segments(atom(), integer(), term()) :: segment_group() | nil
  defp group_from_segments(name, priority, rendered) do
    case normalize_segments(name, rendered) do
      [] -> nil
      segments -> %{name: name, priority: priority, segments: segments}
    end
  end

  @spec render_custom(ModelineSegment.t(), context()) :: term()
  defp render_custom(%ModelineSegment{name: name, render: render}, ctx) do
    render.(ctx)
  rescue
    e ->
      ModelineSegments.warn_once(
        {:custom_segment_exception, name},
        "Modeline segment #{inspect(name)} failed: #{Exception.message(e)}"
      )

      []
  catch
    kind, reason ->
      ModelineSegments.warn_once(
        {:custom_segment_throw, name},
        "Modeline segment #{inspect(name)} crashed: #{inspect(kind)} #{inspect(reason)}"
      )

      []
  end

  @spec normalize_segments(atom(), term()) :: [render_segment()]
  defp normalize_segments(_name, nil), do: []
  defp normalize_segments(_name, []), do: []

  defp normalize_segments(name, {text, fg, bg, opts, target}),
    do: normalize_segment_tuple(name, {text, fg, bg, opts, target})

  defp normalize_segments(name, segments) when is_list(segments) do
    segments
    |> Enum.flat_map(&normalize_segments(name, &1))
  end

  defp normalize_segments(name, invalid) do
    invalid_segment_output(name, invalid)
    []
  end

  @spec normalize_segment_tuple(atom(), term()) :: [render_segment()]
  defp normalize_segment_tuple(name, {text, fg, bg, opts, target})
       when is_binary(text) and is_integer(fg) and is_integer(bg) and is_list(opts) and
              (is_atom(target) or is_nil(target)) do
    with :ok <- validate_segment_text(name, text),
         :ok <- validate_segment_colors(name, fg, bg),
         {:ok, safe_opts} <- validate_segment_opts(name, opts) do
      [{text, fg, bg, safe_opts, target}]
    else
      :error -> []
    end
  end

  defp normalize_segment_tuple(name, invalid) do
    invalid_segment_output(name, invalid)
    []
  end

  @spec validate_segment_text(atom(), binary()) :: :ok | :error
  defp validate_segment_text(name, text) do
    if String.valid?(text) do
      :ok
    else
      invalid_segment_text(name, text)
      :error
    end
  end

  @spec validate_segment_colors(atom(), integer(), integer()) :: :ok | :error
  defp validate_segment_colors(name, fg, bg) do
    if valid_color?(fg) and valid_color?(bg) do
      :ok
    else
      invalid_segment_colors(name, fg, bg)
      :error
    end
  end

  @spec validate_segment_opts(atom(), term()) :: {:ok, keyword()} | :error
  defp validate_segment_opts(name, opts) do
    if Keyword.keyword?(opts) do
      normalize_segment_opts(name, opts)
    else
      invalid_segment_opts(name, opts)
      :error
    end
  end

  @spec normalize_segment_opts(atom(), keyword()) :: {:ok, keyword()} | :error
  defp normalize_segment_opts(name, opts) do
    opts
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      case normalize_segment_opt(key, value) do
        {:ok, opt} -> {:cont, {:ok, [opt | acc]}}
        :error -> {:halt, invalid_segment_opt(name, key, value)}
      end
    end)
    |> normalize_segment_opts_result()
  end

  @spec normalize_segment_opts_result({:ok, keyword()} | :error) :: {:ok, keyword()} | :error
  defp normalize_segment_opts_result({:ok, opts}), do: {:ok, Enum.reverse(opts)}
  defp normalize_segment_opts_result(:error), do: :error

  @spec normalize_segment_opt(atom(), term()) :: {:ok, {atom(), term()}} | :error
  defp normalize_segment_opt(key, value) when key in @boolean_segment_attrs and is_boolean(value),
    do: {:ok, {key, value}}

  defp normalize_segment_opt(:underline_style, value) when value in @underline_styles,
    do: {:ok, {:underline_style, value}}

  defp normalize_segment_opt(:underline_color, value) when is_integer(value) do
    if valid_color?(value), do: {:ok, {:underline_color, value}}, else: :error
  end

  defp normalize_segment_opt(:blend, value)
       when is_integer(value) and value >= 0 and value <= 100,
       do: {:ok, {:blend, value}}

  defp normalize_segment_opt(:font_family, value) when is_binary(value),
    do: {:ok, {:font_family, value}}

  defp normalize_segment_opt(:font_weight, value) when value in @font_weights,
    do: {:ok, {:font_weight, value}}

  defp normalize_segment_opt(:font_slant, value) when value in @font_slants,
    do: {:ok, {:font_slant, value}}

  defp normalize_segment_opt(:font_features, value) when is_map(value) do
    if Enum.all?(value, fn {feature, enabled} -> is_binary(feature) and is_boolean(enabled) end) do
      {:ok, {:font_features, value}}
    else
      :error
    end
  end

  defp normalize_segment_opt(_key, _value), do: :error

  @spec valid_color?(integer()) :: boolean()
  defp valid_color?(value), do: value >= 0 and value <= 0xFF_FFFF

  @spec invalid_segment_text(atom(), binary()) :: :ok
  defp invalid_segment_text(name, text) do
    ModelineSegments.warn_once(
      {:invalid_segment_text, name},
      "Invalid modeline segment #{inspect(name)} text ignored because it is not valid UTF-8: #{inspect(text, binaries: :as_binaries)}"
    )
  end

  @spec invalid_segment_colors(atom(), term(), term()) :: :ok
  defp invalid_segment_colors(name, fg, bg) do
    ModelineSegments.warn_once(
      {:invalid_segment_colors, name},
      "Invalid modeline segment #{inspect(name)} colors ignored: fg=#{inspect(fg)} bg=#{inspect(bg)}"
    )
  end

  @spec invalid_segment_opts(atom(), term()) :: :error
  defp invalid_segment_opts(name, opts) do
    ModelineSegments.warn_once(
      {:invalid_segment_opts, name},
      "Invalid modeline segment #{inspect(name)} options ignored: expected a keyword list, got #{inspect(opts, limit: 20)}"
    )

    :error
  end

  @spec invalid_segment_opt(atom(), atom(), term()) :: :error
  defp invalid_segment_opt(name, key, value) do
    ModelineSegments.warn_once(
      {:invalid_segment_opt, name, key},
      "Invalid modeline segment #{inspect(name)} option ignored: #{inspect(key)}=#{inspect(value)}"
    )

    :error
  end

  @spec invalid_segment_output(atom(), term()) :: :ok
  defp invalid_segment_output(name, invalid) do
    inspected = inspect(invalid, printable_limit: 200, limit: 20)

    ModelineSegments.warn_once(
      {:invalid_segment_output, name},
      "Invalid modeline segment #{inspect(name)} output ignored: #{inspected}"
    )
  end

  @spec fit_segment_groups(
          [segment_group()],
          [segment_group()],
          non_neg_integer(),
          separator_style(),
          non_neg_integer()
        ) :: {[segment_group()], [segment_group()]}
  defp fit_segment_groups(left, right, cols, separator_style, bar_bg) do
    if groups_width(left, right, separator_style, bar_bg) <= cols do
      {left, right}
    else
      drop_lowest_priority(left, right)
      |> fit_segment_groups(cols, separator_style, bar_bg)
    end
  end

  @spec fit_segment_groups(
          {[segment_group()], [segment_group()]},
          non_neg_integer(),
          separator_style(),
          non_neg_integer()
        ) :: {[segment_group()], [segment_group()]}
  defp fit_segment_groups({left, right}, cols, separator_style, bar_bg),
    do: fit_segment_groups(left, right, cols, separator_style, bar_bg)

  @spec drop_lowest_priority([segment_group()], [segment_group()]) ::
          {[segment_group()], [segment_group()]}
  defp drop_lowest_priority([], []), do: {[], []}

  defp drop_lowest_priority(left, right) do
    {side, name} =
      (Enum.map(left, &{:left, &1.name, &1.priority}) ++
         Enum.map(right, &{:right, &1.name, &1.priority}))
      |> Enum.min_by(fn {_side, name, priority} -> {priority, name} end)
      |> then(fn {side, name, _priority} -> {side, name} end)

    {drop_group(left, side, name, :left), drop_group(right, side, name, :right)}
  end

  @spec drop_group([segment_group()], :left | :right, atom(), :left | :right) :: [segment_group()]
  defp drop_group(groups, side, name, side), do: Enum.reject(groups, &(&1.name == name))
  defp drop_group(groups, _drop_side, _name, _own_side), do: groups

  @spec gui_segments_from_groups([segment_group()]) :: [gui_segment()]
  defp gui_segments_from_groups(groups) do
    Enum.flat_map(groups, fn %{name: name, segments: segments} ->
      Enum.map(segments, fn {text, fg, bg, opts, target} -> {name, text, fg, bg, opts, target} end)
    end)
  end

  @spec groups_width([segment_group()], [segment_group()], separator_style(), non_neg_integer()) ::
          non_neg_integer()
  defp groups_width(left, right, separator_style, bar_bg),
    do:
      segments_width(left_segments(left, separator_style, bar_bg)) +
        segments_width(right_segments(right, separator_style, bar_bg))

  @spec left_segments([segment_group()], separator_style(), non_neg_integer()) :: [
          render_segment()
        ]
  defp left_segments(groups, separator_style, bar_bg) do
    groups
    |> groups_with_left_separators(separator_style)
    |> maybe_append_left_boundary(separator_style, bar_bg)
  end

  @spec groups_with_left_separators([segment_group()], separator_style()) :: [render_segment()]
  defp groups_with_left_separators([], _separator_style), do: []

  defp groups_with_left_separators([first | rest], separator_style) do
    Enum.reduce(rest, first.segments, fn group, acc ->
      acc ++ left_separator_between(acc, group.segments, separator_style) ++ group.segments
    end)
  end

  @spec maybe_append_left_boundary([render_segment()], separator_style(), non_neg_integer()) :: [
          render_segment()
        ]
  defp maybe_append_left_boundary([], _separator_style, _bar_bg), do: []

  defp maybe_append_left_boundary(segments, separator_style, bar_bg) do
    case List.last(segments) do
      {_text, _fg, ^bar_bg, _opts, _target} ->
        segments

      {_text, _fg, bg, _opts, _target} ->
        segments ++ [forward_separator(bg, bar_bg, separator_style)]
    end
  end

  @spec left_separator_between([render_segment()], [render_segment()], separator_style()) :: [
          render_segment()
        ]
  defp left_separator_between(previous_segments, next_segments, separator_style) do
    case {List.last(previous_segments), List.first(next_segments)} do
      {{_prev_text, _prev_fg, prev_bg, _prev_opts, _prev_target},
       {_next_text, _next_fg, next_bg, _next_opts, _next_target}} ->
        separator_for_left_transition(prev_bg, next_bg, separator_style)

      _other ->
        []
    end
  end

  @spec separator_for_left_transition(non_neg_integer(), non_neg_integer(), separator_style()) ::
          [render_segment()]
  defp separator_for_left_transition(bg, bg, _separator_style), do: []

  defp separator_for_left_transition(prev_bg, next_bg, separator_style),
    do: [forward_separator(prev_bg, next_bg, separator_style)]

  @spec right_segments([segment_group()], separator_style(), non_neg_integer()) :: [
          render_segment()
        ]
  defp right_segments(groups, separator_style, bar_bg) do
    groups
    |> groups_with_right_separators(separator_style, bar_bg)
  end

  @spec groups_with_right_separators([segment_group()], separator_style(), non_neg_integer()) :: [
          render_segment()
        ]
  defp groups_with_right_separators([], _separator_style, _bar_bg), do: []

  defp groups_with_right_separators([first | rest], separator_style, bar_bg) do
    initial = leading_right_separator(first.segments, separator_style, bar_bg) ++ first.segments

    Enum.reduce(rest, initial, fn group, acc ->
      acc ++ right_separator_between(acc, group.segments, separator_style) ++ group.segments
    end)
  end

  @spec leading_right_separator([render_segment()], separator_style(), non_neg_integer()) :: [
          render_segment()
        ]
  defp leading_right_separator([], _separator_style, _bar_bg), do: []

  defp leading_right_separator(
         [{_text, _fg, bg, _opts, _target} | _rest],
         separator_style,
         bar_bg
       ),
       do: separator_for_right_transition(bar_bg, bg, separator_style)

  @spec right_separator_between([render_segment()], [render_segment()], separator_style()) :: [
          render_segment()
        ]
  defp right_separator_between(previous_segments, next_segments, separator_style) do
    case {List.last(previous_segments), List.first(next_segments)} do
      {{_prev_text, _prev_fg, prev_bg, _prev_opts, _prev_target},
       {_next_text, _next_fg, next_bg, _next_opts, _next_target}} ->
        separator_for_right_transition(prev_bg, next_bg, separator_style)

      _other ->
        []
    end
  end

  @spec separator_for_right_transition(non_neg_integer(), non_neg_integer(), separator_style()) ::
          [render_segment()]
  defp separator_for_right_transition(bg, bg, _separator_style), do: []

  defp separator_for_right_transition(prev_bg, next_bg, separator_style),
    do: [reverse_separator(next_bg, prev_bg, separator_style)]

  @spec forward_separator(non_neg_integer(), non_neg_integer(), separator_style()) ::
          render_segment()
  defp forward_separator(prev_bg, next_bg, separator_style) do
    {char, _reverse_char} = Map.fetch!(@separator_chars, separator_style)
    {char, prev_bg, next_bg, [], nil}
  end

  @spec reverse_separator(non_neg_integer(), non_neg_integer(), separator_style()) ::
          render_segment()
  defp reverse_separator(next_bg, prev_bg, separator_style) do
    {_char, reverse_char} = Map.fetch!(@separator_chars, separator_style)
    {reverse_char, next_bg, prev_bg, [], nil}
  end

  @spec segments_width([render_segment()]) :: non_neg_integer()
  defp segments_width(segments) do
    Enum.reduce(segments, 0, fn {text, _fg, _bg, _opts, _target}, acc ->
      acc + Unicode.display_width(text)
    end)
  end

  @spec emit_segments(non_neg_integer(), non_neg_integer(), [render_segment()]) ::
          {[DisplayList.draw()], [click_region()]}
  defp emit_segments(row, col_off, segments) do
    {commands, click_regions, _col} =
      Enum.reduce(segments, {[], [], col_off}, fn {text, fg, bg, opts, target},
                                                  {cmds, regions, col} ->
        cmd = DisplayList.draw(row, col, text, Face.new([{:fg, fg}, {:bg, bg} | opts]))
        width = Unicode.display_width(text)
        next_col = col + width
        new_regions = click_region(regions, col, next_col, target)
        {[cmd | cmds], new_regions, next_col}
      end)

    {Enum.reverse(commands), Enum.reverse(click_regions)}
  end

  @spec click_region([click_region()], non_neg_integer(), non_neg_integer(), atom() | nil) :: [
          click_region()
        ]
  defp click_region(regions, _col, _next_col, nil), do: regions
  defp click_region(regions, col, next_col, command), do: [{col, next_col, command} | regions]

  @spec render_builtin(atom(), context()) :: [render_segment()]
  defp render_builtin(:mode, ctx), do: render_mode(ctx)
  defp render_builtin(:filename, ctx), do: render_filename(ctx)
  defp render_builtin(:git, ctx), do: build_git_segments(ctx.data, ctx.bar_bg, ctx.theme)
  defp render_builtin(:agent, ctx), do: build_agent_segments(ctx.data, ctx.bar_bg)

  defp render_builtin(:background_agent, ctx),
    do: build_background_agent_segments(ctx.data, ctx.bar_bg, ctx.theme.modeline)

  defp render_builtin(:diagnostics, ctx),
    do: build_diagnostic_segments(ctx.data, ctx.bar_bg, ctx.theme)

  defp render_builtin(:parser, ctx),
    do: build_parser_segments(ctx.data, ctx.bar_bg, ctx.theme.modeline)

  defp render_builtin(:lsp, ctx), do: build_lsp_segments(ctx.data, ctx.bar_bg, ctx.theme.modeline)
  defp render_builtin(:filetype, ctx), do: render_filetype(ctx)
  defp render_builtin(:position, ctx), do: render_position(ctx)
  defp render_builtin(:percent, ctx), do: render_percent(ctx)
  defp render_builtin(:indent, ctx), do: render_indent(ctx)
  defp render_builtin(:selection, _ctx), do: []
  defp render_builtin(_name, _ctx), do: []

  @spec render_mode(context()) :: [render_segment()]
  defp render_mode(ctx) do
    badge = ctx.data[:mode_override] || mode_badge(ctx.data.mode, ctx.data.mode_state)
    [{" #{badge} ", ctx.mode_fg, ctx.mode_bg, [bold: true], nil}]
  end

  @spec render_filename(context()) :: [render_segment()]
  defp render_filename(ctx) do
    data = ctx.data
    buf_indicator = if data.buf_count > 1, do: " [#{data.buf_index}/#{data.buf_count}]", else: ""

    macro_indicator =
      case Map.get(data, :macro_recording, false) do
        {true, reg} -> " recording @#{reg}"
        _other -> ""
      end

    [
      {" #{data.file_name}#{data.dirty_marker}#{buf_indicator}#{macro_indicator} ", ctx.info_fg,
       ctx.info_bg, [], :buffer_list}
    ]
  end

  @spec render_filetype(context()) :: [render_segment()]
  defp render_filetype(ctx) do
    {devicon, devicon_color} = Devicon.icon_and_color(ctx.data.filetype)
    filetype_label = filetype_label(ctx.data.filetype)

    [
      {" #{devicon}", devicon_color, ctx.bar_bg, [], nil},
      {" #{filetype_label} ", ctx.theme.modeline.filetype_fg, ctx.bar_bg, [], :filetype_menu}
    ]
  end

  @spec render_position(context()) :: [render_segment()]
  defp render_position(%{data: %{selection_info: {:chars, count}}} = ctx),
    do: [{" #{count} chars ", ctx.info_fg, ctx.info_bg, [], nil}]

  defp render_position(%{data: %{selection_info: {:lines, count}}} = ctx),
    do: [{" #{count} lines ", ctx.info_fg, ctx.info_bg, [], nil}]

  defp render_position(ctx),
    do: [
      {" #{ctx.data.cursor_line + 1}:#{ctx.data.cursor_col + 1} ", ctx.info_fg, ctx.info_bg, [],
       nil}
    ]

  @spec render_indent(context()) :: [render_segment()]
  defp render_indent(%{data: %{indent_type: type, indent_size: size}} = ctx) do
    label = if type == :tabs, do: "Tabs", else: "Spaces"
    [{" #{label}:#{size} ", ctx.info_fg, ctx.info_bg, [], :indent_picker}]
  end

  defp render_indent(_ctx), do: []

  @spec render_percent(context()) :: [render_segment()]
  defp render_percent(ctx) do
    percent = percent_label(ctx.data.cursor_line, ctx.data.line_count)
    [{" #{percent} ", ctx.mode_fg, ctx.mode_bg, [bold: true], nil}]
  end

  @spec percent_label(non_neg_integer(), non_neg_integer()) :: String.t()
  defp percent_label(_cursor_line, line_count) when line_count <= 1, do: "Top"

  defp percent_label(cursor_line, line_count),
    do: "#{div(cursor_line * 100, max(line_count - 1, 1))}%%"

  @spec build_git_segments(modeline_data(), non_neg_integer(), Theme.t()) :: [render_segment()]
  defp build_git_segments(data, bar_bg, theme) do
    branch = Map.get(data, :git_branch)
    summary = Map.get(data, :git_diff_summary)

    case branch do
      nil ->
        []

      "" ->
        []

      name ->
        [
          {" #{@branch_icon} #{name}", theme.modeline.info_fg, bar_bg, [], nil}
          | build_diff_stat_segments(summary, bar_bg, theme.git)
        ]
    end
  end

  @spec build_diff_stat_segments(git_diff_summary(), non_neg_integer(), Theme.Git.t()) :: [
          render_segment()
        ]
  defp build_diff_stat_segments(nil, _bar_bg, _git_theme), do: []
  defp build_diff_stat_segments({0, 0, 0}, _bar_bg, _git_theme), do: []

  defp build_diff_stat_segments({added, modified, deleted}, bar_bg, git_theme) do
    [
      {added, "+", git_theme.added_fg},
      {modified, "~", git_theme.modified_fg},
      {deleted, "-", git_theme.deleted_fg}
    ]
    |> Enum.filter(fn {count, _prefix, _color} -> count > 0 end)
    |> Enum.map(fn {count, prefix, color} -> {" #{prefix}#{count}", color, bar_bg, [], nil} end)
  end

  @spec build_agent_segments(modeline_data(), non_neg_integer()) :: [render_segment()]
  defp build_agent_segments(data, bar_bg) do
    status = Map.get(data, :agent_status)
    colors = Map.get(data, :agent_theme_colors)

    case {status, colors} do
      {nil, _colors} -> []
      {:idle, c} -> [{" ◯ ", c.status_idle, bar_bg, [], nil}]
      {:plan, c} -> [{" PLAN ", c.status_thinking, bar_bg, [bold: true], nil}]
      {:thinking, c} -> [{" ⟳ ", c.status_thinking, bar_bg, [bold: true], nil}]
      {:tool_executing, c} -> [{" ⚡ ", c.status_tool, bar_bg, [bold: true], nil}]
      {:error, c} -> [{" ✗ ", c.status_error, bar_bg, [bold: true], nil}]
      _other -> []
    end
  end

  @spec build_background_agent_segments(modeline_data(), non_neg_integer(), Theme.Modeline.t()) ::
          [render_segment()]
  defp build_background_agent_segments(data, bar_bg, ml) do
    count = Map.get(data, :background_subagent_count, 0)
    label = Map.get(data, :active_background_subagent_label)

    if count > 0 do
      text = if label, do: " bg:#{count} #{label}", else: " bg:#{count}"
      [{text, ml.info_fg, bar_bg, [], :agent_session_switcher}]
    else
      []
    end
  end

  @spec build_diagnostic_segments(modeline_data(), non_neg_integer(), Theme.t()) :: [
          render_segment()
        ]
  defp build_diagnostic_segments(%{diagnostic_counts: nil}, _bar_bg, _theme), do: []
  defp build_diagnostic_segments(%{diagnostic_counts: {0, 0, 0, 0}}, _bar_bg, _theme), do: []

  defp build_diagnostic_segments(
         %{diagnostic_counts: {errors, warnings, info, _hints}},
         bar_bg,
         theme
       ) do
    gutter = theme.gutter

    []
    |> maybe_add_diagnostic(errors, @diag_error_icon, gutter.error_fg, bar_bg)
    |> maybe_add_diagnostic(warnings, @diag_warning_icon, gutter.warning_fg, bar_bg)
    |> maybe_add_diagnostic(info, @diag_info_icon, gutter.info_fg, bar_bg)
    |> Enum.reverse()
  end

  defp build_diagnostic_segments(_data, _bar_bg, _theme), do: []

  @spec maybe_add_diagnostic(
          [render_segment()],
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [render_segment()]
  defp maybe_add_diagnostic(segments, 0, _icon, _fg, _bar_bg), do: segments

  defp maybe_add_diagnostic(segments, count, icon, fg, bar_bg),
    do: [{" #{icon} #{count}", fg, bar_bg, [], :diagnostic_picker} | segments]

  @spec build_lsp_segments(modeline_data(), non_neg_integer(), Theme.Modeline.t()) :: [
          render_segment()
        ]
  defp build_lsp_segments(data, bar_bg, ml) do
    case Map.get(data, :lsp_status) do
      :ready -> [{"●", ml.lsp_ready || 0x98BE65, bar_bg, [], :lsp_info}]
      :initializing -> [{"⟳", ml.lsp_initializing || 0xECBE7B, bar_bg, [bold: true], :lsp_info}]
      :starting -> [{"◯", ml.lsp_starting || 0x5B6268, bar_bg, [], :lsp_info}]
      :error -> [{"✗", ml.lsp_error || 0xFF6C6B, bar_bg, [bold: true], :lsp_info}]
      _other -> []
    end
  end

  @spec build_parser_segments(modeline_data(), non_neg_integer(), Theme.Modeline.t()) :: [
          render_segment()
        ]
  defp build_parser_segments(data, bar_bg, ml) do
    case Map.get(data, :parser_status) do
      :unavailable ->
        [{"🌳✗", ml.lsp_error || 0xFF6C6B, bar_bg, [bold: true], :parser_restart}]

      :restarting ->
        [{"🌳⟳", ml.lsp_initializing || 0xECBE7B, bar_bg, [bold: true], :parser_restart}]

      _other ->
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
  defp mode_badge(:delete_confirm, _state), do: "DELETE"

  @spec filetype_label(atom()) :: String.t()
  defp filetype_label(filetype) do
    case Minga.Language.Registry.get(filetype) do
      %{label: label} when is_binary(label) -> label
      _other -> filetype |> Atom.to_string() |> String.capitalize()
    end
  end
end
