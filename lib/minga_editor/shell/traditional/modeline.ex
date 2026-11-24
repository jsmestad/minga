defmodule MingaEditor.Shell.Traditional.Modeline do
  @moduledoc """
  The modeline: the one place Minga's state is always visible, said once, in words.

  `gui_segments/3` turns the status bar facts into ordered `Minga.RenderModel.UI.StatusBar.Segment`s for the semantic status bar. The default order follows `docs/design/surfaces.md`: mode, needs-you, file, change position, git, Minga, diagnostics and persistent problems on the left; filetype and position on the right. Segment selection comes from `Minga.Config.Options` (`:modeline_left_segments`, `:modeline_right_segments`), and custom segments come from `Minga.Config.ModelineSegments`.

  Each segment carries a drop rank. When a frontend's window is too narrow it applies the ranks in order, lowest first: optional and custom segments, then filetype, position, git, then Minga's words shrink to the state mark and its step count, then warnings. Mode, needs-you, the file name, change position, errors and persistent problems never drop.

  Clicks do what the segment's key does: a designed segment names its leader key, and both the click target and the key hint resolve through the active leader trie, so a rebinding moves them together.
  """

  alias Minga.Config.ModelineSegment
  alias Minga.Config.ModelineSegments
  alias Minga.Design.Tokens
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults, as: KeymapDefaults
  alias Minga.Mode
  alias Minga.RenderModel.UI.StatusBar.Segment
  alias MingaEditor.StatusBar.PlanLimit
  alias MingaEditor.UI.Theme

  import Minga.Keymap.Sigil

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
          optional(:safe_mode) => boolean(),
          :file_name => String.t(),
          :filetype => atom(),
          :dirty_marker => String.t(),
          :cursor_line => non_neg_integer(),
          :cursor_col => non_neg_integer(),
          :line_count => non_neg_integer(),
          :buf_index => pos_integer(),
          :buf_count => non_neg_integer(),
          :macro_recording => {true, String.t()} | false,
          optional(:workspace_label) => String.t(),
          optional(:workspace_draft_count) => non_neg_integer(),
          optional(:workspace_conflict_count) => non_neg_integer(),
          optional(:merge_conflict_count) => non_neg_integer(),
          optional(:agent_status) => MingaEditor.State.Agent.status() | :needs_you,
          optional(:active_tool_name) => String.t() | nil,
          optional(:agent_status_command) => String.t() | nil,
          optional(:agent_theme_colors) => MingaEditor.UI.Theme.Agent.t() | nil,
          optional(:mode_override) => String.t() | nil,
          optional(:lsp_status) => lsp_status(),
          optional(:parser_status) => parser_status(),
          optional(:git_branch) => String.t() | nil,
          optional(:git_diff_summary) => git_diff_summary(),
          optional(:git_degraded) => boolean(),
          optional(:diagnostic_counts) =>
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil,
          optional(:indent_type) => :spaces | :tabs,
          optional(:indent_size) => pos_integer(),
          optional(:selection_info) =>
            {:chars, non_neg_integer()} | {:lines, pos_integer()} | nil,
          optional(:background_subagent_count) => non_neg_integer(),
          optional(:active_background_subagent_label) => String.t() | nil,
          optional(:plan_limit) => MingaEditor.StatusBar.PlanLimit.t() | nil,
          optional(:needs_you_count) => non_neg_integer(),
          optional(:minga_progress) => {non_neg_integer(), pos_integer()} | nil,
          optional(:change_position) => {pos_integer(), pos_integer()} | nil,
          optional(:failed_language_servers) => [String.t()],
          optional(:leader_trie) => Bindings.node_t(),
          optional(:key_hints?) => boolean()
        }

  @type render_segment :: ModelineSegment.render_segment()
  @type gui_segments :: %{left: [Segment.t()], right: [Segment.t()]}
  @type context :: %{
          data: modeline_data(),
          theme: Theme.t(),
          bar_bg: non_neg_integer(),
          bar_fg: non_neg_integer(),
          info_bg: non_neg_integer(),
          info_fg: non_neg_integer(),
          mode_bg: non_neg_integer(),
          mode_fg: non_neg_integer(),
          leader_trie: Bindings.node_t(),
          key_hints?: boolean()
        }

  @boolean_segment_attrs [:bold, :italic, :underline, :strikethrough, :reverse]
  @underline_styles [:line, :curl, :dashed, :dotted, :double]
  @font_weights [:thin, :light, :regular, :medium, :semibold, :bold, :heavy, :black]
  @font_slants [:roman, :italic, :oblique]

  # Drop ranks, applied lowest first when the window narrows (docs/design/surfaces.md).
  # 0 never drops: mode, needs-you, the file name, change position, errors and problems.
  @never 0
  @drop_optional 1
  @drop_filetype 2
  @drop_position 3
  @drop_git 4
  @drop_minga 5
  @drop_warnings 6

  # The designed key of each clickable segment; the click runs whatever that key runs.
  @needs_you_keys ~k(a a)
  @file_keys ~k(,)
  @minga_keys ~k(a v)
  @diagnostics_keys ~k(c x)
  @git_keys ~k(g g)

  @doc "Returns the built-in modeline segment names."
  @spec built_in_segments() :: [atom()]
  def built_in_segments, do: ModelineSegments.reserved_names()

  @doc "Returns the configured modeline segments, in order, for the semantic status bar."
  @spec gui_segments(modeline_data(), Theme.t()) :: gui_segments()
  @spec gui_segments(modeline_data(), Theme.t(), ModelineSegments.table()) :: gui_segments()
  def gui_segments(
        data,
        theme \\ MingaEditor.UI.Theme.get!(MingaEditor.UI.Theme.default()),
        modeline_segments_table \\ ModelineSegments
      ) do
    ctx = context(data, theme)
    {left_names, right_names} = configured_segment_names(modeline_segments_table)
    left = render_side(left_names, ctx, modeline_segments_table)
    right = render_side(right_names, ctx, modeline_segments_table)

    %{left: left, right: right}
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
      mode_fg: mode_fg,
      leader_trie: Map.get_lazy(data, :leader_trie, &Minga.Keymap.default_leader_trie/0),
      key_hints?: Map.get(data, :key_hints?, true)
    }
  end

  @spec configured_segment_names(ModelineSegments.table()) :: {[atom()], [atom()]}
  defp configured_segment_names(modeline_segments_table) do
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

  @spec render_side([atom()], context(), ModelineSegments.table()) :: [Segment.t()]
  defp render_side(names, ctx, modeline_segments_table) do
    names
    |> Enum.reduce([], fn name, acc ->
      rendered = render_segment(name, ctx, modeline_segments_table)
      collect_segments(name, rendered, acc)
    end)
    |> Enum.reverse()
  end

  @spec render_custom(ModelineSegment.t(), context()) :: term()
  defp render_custom(%ModelineSegment{render: render}, ctx) do
    case render.(ctx) do
      {:extension_callback, _source, _module, _function, {:ok, returned}} -> returned
      {:extension_callback, _source, _module, _function, {:error, _failure}} -> []
      returned -> returned
    end
  end

  @spec collect_segments(atom(), term(), [Segment.t()]) :: [Segment.t()]
  defp collect_segments(_name, nil, acc), do: acc
  defp collect_segments(_name, [], acc), do: acc
  defp collect_segments(_name, %Segment{} = segment, acc), do: [segment | acc]

  defp collect_segments(name, segments, acc) when is_list(segments) do
    collect_segment_list(segments, name, acc)
  end

  defp collect_segments(name, {text, fg, bg, opts, target}, acc)
       when is_binary(text) and is_integer(fg) and is_integer(bg) and is_list(opts) and
              (is_atom(target) or is_nil(target)) do
    with :ok <- validate_segment_text(name, text),
         :ok <- validate_segment_colors(name, fg, bg),
         :ok <- validate_segment_opts(name, opts) do
      # A custom segment is not part of the design's order, so it is among the first to give way.
      [
        %Segment{
          id: name,
          text: text,
          fg: fg,
          bg: bg,
          style: opts,
          target: target,
          drop: @drop_optional
        }
        | acc
      ]
    else
      :error -> acc
    end
  end

  defp collect_segments(name, invalid, acc) do
    invalid_segment_output(name, invalid)
    acc
  end

  @spec collect_segment_list([term()], atom(), [Segment.t()]) :: [Segment.t()]
  defp collect_segment_list([], _name, acc), do: acc

  defp collect_segment_list([segment | rest], name, acc) do
    collect_segment_list(rest, name, collect_segments(name, segment, acc))
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

  @spec validate_segment_opts(atom(), term()) :: :ok | :error
  defp validate_segment_opts(name, opts) do
    if Keyword.keyword?(opts) do
      validate_keyword_opts(name, opts)
    else
      invalid_segment_opts(name, opts)
    end
  end

  @spec validate_keyword_opts(atom(), keyword()) :: :ok | :error
  defp validate_keyword_opts(_name, []), do: :ok

  defp validate_keyword_opts(name, [{key, value} | rest]) do
    if valid_segment_opt?(key, value) do
      validate_keyword_opts(name, rest)
    else
      invalid_segment_opt(name, key, value)
    end
  end

  @spec valid_segment_opt?(atom(), term()) :: boolean()
  defp valid_segment_opt?(key, value) when key in @boolean_segment_attrs, do: is_boolean(value)
  defp valid_segment_opt?(:underline_style, value), do: value in @underline_styles
  defp valid_segment_opt?(:underline_color, value), do: is_integer(value) and valid_color?(value)
  defp valid_segment_opt?(:blend, value), do: is_integer(value) and value in 0..100
  defp valid_segment_opt?(:font_family, value), do: is_binary(value)
  defp valid_segment_opt?(:font_weight, value), do: value in @font_weights
  defp valid_segment_opt?(:font_slant, value), do: value in @font_slants

  defp valid_segment_opt?(:font_features, value) when is_map(value) do
    Enum.all?(value, fn {feature, enabled} -> is_binary(feature) and is_boolean(enabled) end)
  end

  defp valid_segment_opt?(_key, _value), do: false

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

  @spec render_segment(atom(), context(), ModelineSegments.table()) :: term()
  defp render_segment(:mode, ctx, _table), do: mode_segment(ctx)
  defp render_segment(:needs_you, ctx, _table), do: needs_you_segment(ctx)
  defp render_segment(:filename, ctx, _table), do: file_segment(ctx)
  defp render_segment(:change, ctx, _table), do: change_segment(ctx)
  defp render_segment(:git, ctx, _table), do: git_segment(ctx)
  defp render_segment(:minga, ctx, _table), do: minga_segment(ctx)
  # `:agent` is the segment's name before it spoke as Minga; configs that list it keep working.
  defp render_segment(:agent, ctx, _table), do: minga_segment(ctx)
  defp render_segment(:diagnostics, ctx, _table), do: diagnostic_segments(ctx)
  defp render_segment(:lsp, ctx, _table), do: lsp_segment(ctx)
  defp render_segment(:parser, ctx, _table), do: parser_segment(ctx)
  defp render_segment(:filetype, ctx, _table), do: filetype_segment(ctx)
  defp render_segment(:position, ctx, _table), do: position_segment(ctx)
  defp render_segment(:workspace, ctx, _table), do: workspace_segment(ctx)
  defp render_segment(:background_agent, ctx, _table), do: background_agent_segment(ctx)
  defp render_segment(:plan_limit, ctx, _table), do: plan_limit_segment(ctx)
  defp render_segment(:percent, ctx, _table), do: percent_segment(ctx)
  defp render_segment(:indent, ctx, _table), do: indent_segment(ctx)

  defp render_segment(:draft, ctx, _table),
    do: count_segment(ctx, :draft, :workspace_draft_count, "D", :workspace_list, "draft")

  defp render_segment(:conflict, ctx, _table),
    do: count_segment(ctx, :conflict, :workspace_conflict_count, "C", :workspace_list, "conflict")

  defp render_segment(:merge_conflict, ctx, _table) do
    count_segment(
      ctx,
      :merge_conflict,
      :merge_conflict_count,
      "X",
      :next_merge_conflict,
      "merge conflict"
    )
  end

  defp render_segment(:selection, _ctx, _table), do: []

  defp render_segment(name, ctx, table) do
    case ModelineSegments.lookup(table, name) do
      %ModelineSegment{} = segment ->
        render_custom(segment, ctx)

      nil ->
        ModelineSegments.warn_once(
          table,
          {:unknown_segment, name},
          "Unknown modeline segment #{inspect(name)} ignored"
        )

        nil
    end
  end

  # ── Designed segments ──────────────────────────────────────────────────────

  @spec mode_segment(context()) :: [Segment.t()]
  defp mode_segment(ctx) do
    badge = ctx.data[:mode_override] || mode_badge(ctx.data.mode, ctx.data.mode_state)
    badge = safe_mode_badge(badge, Map.get(ctx.data, :safe_mode, false))

    [
      %Segment{
        id: :mode,
        text: badge,
        fg: ctx.mode_fg,
        bg: ctx.mode_bg,
        style: [bold: true],
        drop: @never,
        label: "#{String.capitalize(badge)} mode"
      }
    ]
  end

  @spec safe_mode_badge(String.t(), boolean()) :: String.t()
  defp safe_mode_badge(badge, true), do: "[SAFE] #{badge}"
  defp safe_mode_badge(badge, false), do: badge

  @spec needs_you_segment(context()) :: [Segment.t()]
  defp needs_you_segment(ctx) do
    case Map.get(ctx.data, :needs_you_count, 0) do
      0 ->
        []

      count ->
        word = Tokens.state_word(:needs_you)
        text = if count == 1, do: word, else: "#{word} #{count}"

        segment = %Segment{
          id: :needs_you,
          text: text,
          fg: Theme.state_color(ctx.theme, :needs_you),
          bg: ctx.bar_bg,
          style: [bold: true],
          drop: @never,
          state: :needs_you,
          label: needs_you_label(count)
        }

        [with_leader_key(segment, ctx, @needs_you_keys)]
    end
  end

  @spec needs_you_label(pos_integer()) :: String.t()
  defp needs_you_label(1), do: "1 task needs you"
  defp needs_you_label(count), do: "#{count} tasks need you"

  @spec file_segment(context()) :: [Segment.t()]
  defp file_segment(ctx) do
    name = ctx.data.file_name
    unsaved? = String.trim(ctx.data.dirty_marker) != ""

    # The zero-buffers launchpad (#2689) has no file, so the segment is absent rather than blank.
    if String.trim(name) == "" do
      []
    else
      segment = %Segment{
        id: :filename,
        text: if(unsaved?, do: "#{name} ●", else: name),
        fg: ctx.info_fg,
        bg: ctx.bar_bg,
        drop: @never,
        label: if(unsaved?, do: "#{name}, unsaved", else: name)
      }

      [with_leader_key(segment, ctx, @file_keys)]
    end
  end

  # The position among Minga's changes in this file, while the cursor is inside one.
  # The change gutter (#4050) supplies it and binds the key that jumps between changes.
  @spec change_segment(context()) :: [Segment.t()]
  defp change_segment(ctx) do
    case Map.get(ctx.data, :change_position) do
      {index, total} ->
        [
          %Segment{
            id: :change,
            text: "change #{index}/#{total}",
            fg: Theme.role_color(ctx.theme, :minga),
            bg: ctx.bar_bg,
            drop: @never,
            label: "Minga's change #{index} of #{total}"
          }
        ]

      nil ->
        []
    end
  end

  @spec git_segment(context()) :: [Segment.t()]
  defp git_segment(ctx) do
    case Map.get(ctx.data, :git_branch) do
      branch when branch in [nil, ""] ->
        []

      branch ->
        changed = changed_lines(Map.get(ctx.data, :git_diff_summary))
        degraded? = Map.get(ctx.data, :git_degraded, false)
        count = if changed > 0, do: " +#{changed}", else: ""
        partial = if degraded?, do: " (partial)", else: ""

        segment = %Segment{
          id: :git,
          text: branch <> count <> partial,
          fg: ctx.info_fg,
          bg: ctx.bar_bg,
          drop: @drop_git,
          label: git_label(branch, changed, degraded?)
        }

        [with_leader_key(segment, ctx, @git_keys)]
    end
  end

  @spec changed_lines(git_diff_summary()) :: non_neg_integer()
  defp changed_lines({added, modified, deleted}), do: added + modified + deleted
  defp changed_lines(nil), do: 0

  @spec git_label(String.t(), non_neg_integer(), boolean()) :: String.t()
  defp git_label(branch, changed, degraded?) do
    lines = if changed > 0, do: ", #{changed} #{plural(changed, "changed line", "changed lines")}"
    partial = if degraded?, do: ", status incomplete"
    "Branch #{branch}#{lines}#{partial}"
  end

  # Minga's state, said once: the token mark and word, its step through the plan, then the status command text.
  # In a narrow window it shrinks to the mark and the step count.
  @spec minga_segment(context()) :: [Segment.t()]
  defp minga_segment(ctx) do
    state = Tokens.agent_status_state(Map.get(ctx.data, :agent_status))
    progress = Map.get(ctx.data, :minga_progress)
    custom = custom_status_text(Map.get(ctx.data, :agent_status_command))
    minga_segment(ctx, state, progress, custom)
  end

  @spec minga_segment(
          context(),
          Tokens.state_id() | nil,
          {non_neg_integer(), pos_integer()} | nil,
          String.t() | nil
        ) :: [Segment.t()]
  defp minga_segment(_ctx, nil, _progress, nil), do: []

  defp minga_segment(ctx, nil, _progress, custom) do
    [
      %Segment{
        id: :minga,
        text: custom,
        fg: ctx.info_fg,
        bg: ctx.bar_bg,
        drop: @drop_minga,
        label: custom
      }
    ]
  end

  defp minga_segment(ctx, state, progress, custom) do
    step = progress_text(progress)

    words =
      Enum.reject(["Minga", String.downcase(Tokens.state_word(state)), step, custom], &is_nil/1)

    segment = %Segment{
      id: :minga,
      text: Enum.join(words, " "),
      fg: Theme.state_color(ctx.theme, state),
      bg: ctx.bar_bg,
      style: [bold: true],
      drop: @drop_minga,
      compact: step || "",
      state: state,
      label: minga_label(state, progress)
    }

    [with_leader_key(segment, ctx, @minga_keys)]
  end

  @spec custom_status_text(String.t() | nil) :: String.t() | nil
  defp custom_status_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp custom_status_text(_text), do: nil

  @spec progress_text({non_neg_integer(), pos_integer()} | nil) :: String.t() | nil
  defp progress_text({step, steps}), do: "#{step}/#{steps}"
  defp progress_text(nil), do: nil

  @spec minga_label(Tokens.state_id(), {non_neg_integer(), pos_integer()} | nil) :: String.t()
  defp minga_label(state, {step, steps}),
    do: "#{Tokens.state(state).accessibility_label}, step #{step} of #{steps}"

  defp minga_label(state, nil), do: Tokens.state(state).accessibility_label

  # Errors never drop; warnings give way after Minga's words.
  # The count is the text; each frontend draws the severity's mark before it (SF Symbols on macOS, E and W in the TUI).
  @spec diagnostic_segments(context()) :: [Segment.t()]
  defp diagnostic_segments(%{data: %{diagnostic_counts: {errors, warnings, _info, _hints}}} = ctx) do
    [
      diagnostic_segment(ctx, :errors, errors, :failure, @never, "error"),
      diagnostic_segment(ctx, :warnings, warnings, :warning, @drop_warnings, "warning")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp diagnostic_segments(_ctx), do: []

  @spec diagnostic_segment(
          context(),
          :errors | :warnings,
          non_neg_integer(),
          Tokens.color_role(),
          non_neg_integer(),
          String.t()
        ) :: Segment.t() | nil
  defp diagnostic_segment(_ctx, _id, 0, _role, _drop, _noun), do: nil

  defp diagnostic_segment(ctx, id, count, role, drop, noun) do
    segment = %Segment{
      id: id,
      text: Integer.to_string(count),
      fg: Theme.role_color(ctx.theme, role),
      bg: ctx.bar_bg,
      drop: drop,
      label: "#{count} #{plural(count, noun, noun <> "s")}"
    }

    with_leader_key(segment, ctx, @diagnostics_keys)
  end

  # A failed language server is a persistent problem: it takes the diagnostics slot and never drops.
  # So a clean count is never shown while nothing is checking.
  @spec lsp_segment(context()) :: [Segment.t()]
  defp lsp_segment(%{data: %{lsp_status: :error}} = ctx) do
    text =
      case Map.get(ctx.data, :failed_language_servers, []) do
        [] -> "Language server failed"
        names -> "#{Enum.join(names, ", ")} failed"
      end

    [problem_segment(ctx, text, :lsp_info)]
  end

  defp lsp_segment(_ctx), do: []

  @spec parser_segment(context()) :: [Segment.t()]
  defp parser_segment(%{data: %{parser_status: :unavailable}} = ctx),
    do: [problem_segment(ctx, "Parser failed", :parser_restart)]

  defp parser_segment(%{data: %{parser_status: :restarting}} = ctx) do
    segment = %Segment{
      id: :parser,
      text: "Parser restarting",
      fg: Theme.role_color(ctx.theme, :warning),
      bg: ctx.bar_bg,
      drop: @drop_optional,
      label: "Parser restarting"
    }

    [with_command_key(segment, ctx, :parser_restart)]
  end

  defp parser_segment(_ctx), do: []

  @spec problem_segment(context(), String.t(), atom()) :: Segment.t()
  defp problem_segment(ctx, text, command) do
    segment = %Segment{
      id: :problem,
      text: text,
      fg: Theme.role_color(ctx.theme, :failure),
      bg: ctx.bar_bg,
      style: [bold: true],
      drop: @never,
      label: text
    }

    with_command_key(segment, ctx, command)
  end

  @spec filetype_segment(context()) :: [Segment.t()]
  defp filetype_segment(ctx) do
    label = filetype_label(ctx.data.filetype)

    segment = %Segment{
      id: :filetype,
      text: label,
      fg: ctx.theme.modeline.filetype_fg,
      bg: ctx.bar_bg,
      drop: @drop_filetype,
      label: label
    }

    [with_command_key(segment, ctx, :filetype_menu)]
  end

  # Always line:col, in Visual mode too (docs/design/surfaces.md).
  @spec position_segment(context()) :: [Segment.t()]
  defp position_segment(ctx) do
    line = ctx.data.cursor_line + 1
    col = ctx.data.cursor_col + 1

    [
      %Segment{
        id: :position,
        text: "#{line}:#{col}",
        fg: ctx.info_fg,
        bg: ctx.bar_bg,
        drop: @drop_position,
        label: "Line #{line}, column #{col}"
      }
    ]
  end

  # ── Optional built-in segments ─────────────────────────────────────────────
  # Not in the design's order: shown only when configured or when they have something to say, and the first to give way.

  @spec workspace_segment(context()) :: [Segment.t()]
  defp workspace_segment(ctx) do
    label = Map.get(ctx.data, :workspace_label, "Files")
    [optional_segment(ctx, :workspace, "W:#{label}", :workspace_list, "Workspace #{label}")]
  end

  @spec background_agent_segment(context()) :: [Segment.t()]
  defp background_agent_segment(ctx) do
    count = Map.get(ctx.data, :background_subagent_count, 0)
    label = Map.get(ctx.data, :active_background_subagent_label)

    if count > 0 do
      text = if label, do: "bg:#{count} #{label}", else: "bg:#{count}"
      meaning = "#{count} background #{plural(count, "subagent", "subagents")} running"
      [optional_segment(ctx, :background_agent, text, :agent_session_switcher, meaning)]
    else
      []
    end
  end

  # A click opens the model picker: the limit notification's "Choose another model" action.
  @spec plan_limit_segment(context()) :: [Segment.t()]
  defp plan_limit_segment(ctx) do
    case Map.get(ctx.data, :plan_limit) do
      %PlanLimit{level: level, text: text} ->
        {role, style} = if level == :rejected, do: {:failure, [bold: true]}, else: {:warning, []}

        segment = %{
          optional_segment(ctx, :plan_limit, text, :agent_pick_model, text)
          | fg: Theme.role_color(ctx.theme, role),
            style: style
        }

        [segment]

      nil ->
        []
    end
  end

  @spec percent_segment(context()) :: [Segment.t()]
  defp percent_segment(ctx) do
    percent = percent_label(ctx.data.cursor_line, ctx.data.line_count)
    [optional_segment(ctx, :percent, percent, nil, "#{percent} through the file")]
  end

  @spec percent_label(non_neg_integer(), non_neg_integer()) :: String.t()
  defp percent_label(_cursor_line, line_count) when line_count <= 1, do: "Top"

  defp percent_label(cursor_line, line_count),
    do: "#{div(cursor_line * 100, max(line_count - 1, 1))}%"

  @spec indent_segment(context()) :: [Segment.t()]
  defp indent_segment(%{data: %{indent_type: type, indent_size: size}} = ctx) do
    label = if type == :tabs, do: "Tabs", else: "Spaces"
    [optional_segment(ctx, :indent, "#{label}:#{size}", :indent_picker, "#{label}, #{size} wide")]
  end

  defp indent_segment(_ctx), do: []

  @spec count_segment(context(), atom(), atom(), String.t(), atom(), String.t()) :: [Segment.t()]
  defp count_segment(ctx, id, key, letter, target, noun) do
    case Map.get(ctx.data, key, 0) do
      0 ->
        []

      count ->
        meaning = "#{count} #{plural(count, noun, noun <> "s")}"
        segment = optional_segment(ctx, id, "#{letter}#{count}", target, meaning)
        [%{segment | style: [bold: true]}]
    end
  end

  @spec optional_segment(context(), atom(), String.t(), atom() | nil, String.t()) :: Segment.t()
  defp optional_segment(ctx, id, text, target, label) do
    segment = %Segment{
      id: id,
      text: text,
      fg: ctx.info_fg,
      bg: ctx.bar_bg,
      drop: @drop_optional,
      label: label
    }

    if target, do: with_command_key(segment, ctx, target), else: segment
  end

  @spec plural(non_neg_integer(), String.t(), String.t()) :: String.t()
  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many

  # ── Keys ───────────────────────────────────────────────────────────────────

  # A designed segment does what its leader key does: the click runs the command bound there, and the hint names it.
  # Nothing bound there means no click and no hint.
  @spec with_leader_key(Segment.t(), context(), [Bindings.key()]) :: Segment.t()
  defp with_leader_key(%Segment{} = segment, ctx, keys) do
    case Bindings.lookup_sequence(ctx.leader_trie, keys) do
      {:command, command, _description} when is_atom(command) ->
        %{segment | target: command, key: key_hint(ctx, keys)}

      _unbound ->
        segment
    end
  end

  # A segment that names its command shows the shortest leader key bound to it, if any.
  @spec with_command_key(Segment.t(), context(), atom()) :: Segment.t()
  defp with_command_key(%Segment{} = segment, ctx, command) do
    case Bindings.sequences_for_command(ctx.leader_trie, command) do
      [keys | _longer] -> %{segment | target: command, key: key_hint(ctx, keys)}
      [] -> %{segment | target: command}
    end
  end

  @spec key_hint(context(), [Bindings.key()]) :: String.t()
  defp key_hint(%{key_hints?: false}, _keys), do: ""

  defp key_hint(_ctx, keys),
    do: Bindings.format_sequence([KeymapDefaults.leader_key() | keys])

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
  defp mode_badge(:eval, _state), do: "EVAL"
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
