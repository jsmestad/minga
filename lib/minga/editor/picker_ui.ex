defmodule Minga.Editor.PickerUI do
  @moduledoc """
  Picker UI — open, key handling, rendering, and close.

  Manages the fuzzy-picker overlay used by the command palette, file finder,
  and buffer list. All functions are pure `state → state` or
  `state → {state, action}` transformations; the GenServer dispatches any
  returned action tuple.

  ## Action tuples

  `handle_key/3` may return `{state, {:execute_command, cmd}}` when the user
  confirms a selection that triggers a command (e.g. command palette → `:save`).
  The caller (`Editor`) is responsible for dispatching that action.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Picker
  alias Minga.Port.Protocol
  alias Minga.WhichKey

  import Bitwise

  @ctrl Protocol.mod_ctrl()

  @escape 27
  @enter 13
  @arrow_down 57_353
  @arrow_up 57_352

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Action the GenServer should dispatch after handle_key/3."
  @type action :: {:execute_command, term()}

  @doc "Opens the picker for the given source module."
  @spec open(state(), module()) :: state()
  def open(state, source_module) do
    items = source_module.candidates(state)

    case items do
      [] ->
        state

      _ ->
        picker = Picker.new(items, title: source_module.title(), max_visible: 10)

        # Clear whichkey state if active
        new_state =
          if state.whichkey_timer do
            WhichKey.cancel_timeout(state.whichkey_timer)
            %{state | whichkey_node: nil, whichkey_timer: nil, show_whichkey: false}
          else
            state
          end

        %{
          new_state
          | picker: picker,
            picker_source: source_module,
            picker_restore: state.active_buffer
        }
    end
  end

  @doc """
  Handles a key event while the picker is open.

  Returns either `state` or `{state, action}` when the caller must dispatch
  a command (e.g. command-palette selection).
  """
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          state() | {state(), action()}
  def handle_key(%{picker_source: source} = state, @escape, _mods) do
    new_state = source.on_cancel(state)
    close(new_state)
  end

  def handle_key(%{picker: picker, picker_source: source} = state, @enter, _mods) do
    case Picker.selected_item(picker) do
      nil ->
        close(state)

      item ->
        new_state = close(state)
        new_state = source.on_select(item, new_state)

        case Map.get(new_state, :pending_command) do
          nil -> new_state
          cmd -> {Map.delete(new_state, :pending_command), {:execute_command, cmd}}
        end
    end
  end

  # C-j or arrow down → move selection down
  def handle_key(%{picker: picker} = state, cp, mods)
      when (cp == ?j and band(mods, @ctrl) != 0) or cp == @arrow_down do
    new_picker = Picker.move_down(picker)
    state = %{state | picker: new_picker}
    maybe_preview_selection(state)
  end

  # C-k or arrow up → move selection up
  def handle_key(%{picker: picker} = state, cp, mods)
      when (cp == ?k and band(mods, @ctrl) != 0) or cp == @arrow_up do
    new_picker = Picker.move_up(picker)
    state = %{state | picker: new_picker}
    maybe_preview_selection(state)
  end

  # Backspace
  def handle_key(%{picker: picker} = state, cp, _mods) when cp in [8, 127] do
    new_picker = Picker.backspace(picker)
    state = %{state | picker: new_picker}
    maybe_preview_selection(state)
  end

  # Printable characters → filter
  def handle_key(%{picker: picker} = state, codepoint, 0)
      when codepoint >= 32 and codepoint <= 0x10FFFF do
    char =
      try do
        <<codepoint::utf8>>
      rescue
        ArgumentError -> nil
      end

    case char do
      nil ->
        state

      c ->
        new_picker = Picker.type_char(picker, c)
        state = %{state | picker: new_picker}
        maybe_preview_selection(state)
    end
  end

  # Ignore all other keys
  def handle_key(state, _cp, _mods), do: state

  @doc "Renders the picker overlay. Returns `{commands, cursor_pos | nil}`."
  @spec render(state(), term()) ::
          {[binary()], {non_neg_integer(), non_neg_integer()} | nil}
  def render(%{picker: nil}, _viewport), do: {[], nil}

  def render(%{picker: picker}, viewport) do
    {visible, selected_offset} = Picker.visible_items(picker)
    item_count = length(visible)

    # Layout: items grow upward from row N-2, prompt on row N-1
    prompt_row = viewport.rows - 1
    separator_row = prompt_row - item_count - 1
    first_item_row = separator_row + 1

    # Background colors
    bg = 0x1E2127
    sel_bg = 0x3E4451
    prompt_bg = 0x1E2127
    dim_fg = 0x5C6370
    text_fg = 0xABB2BF
    highlight_fg = 0xFFFFFF

    # Separator line
    title = picker.title
    filter_info = "#{Picker.count(picker)}/#{Picker.total(picker)}"

    sep_text =
      " #{title} " <>
        String.duplicate(
          "─",
          max(0, viewport.cols - String.length(title) - String.length(filter_info) - 4)
        ) <> " #{filter_info} "

    separator_cmd =
      if separator_row >= 0 do
        [
          Protocol.encode_draw(separator_row, 0, String.pad_trailing(sep_text, viewport.cols),
            fg: dim_fg,
            bg: bg
          )
        ]
      else
        []
      end

    # Match highlight color (yellow/gold)
    match_fg = 0xE5C07B

    picker_colors = %{
      text_fg: text_fg,
      highlight_fg: highlight_fg,
      dim_fg: dim_fg,
      bg: bg,
      sel_bg: sel_bg,
      match_fg: match_fg
    }

    item_commands =
      visible
      |> Enum.with_index()
      |> Enum.flat_map(fn {{_id, label, desc}, idx} ->
        row = first_item_row + idx

        if row < 0 or row >= viewport.rows do
          []
        else
          render_item(
            row,
            label,
            desc,
            idx == selected_offset,
            picker.query,
            viewport.cols,
            picker_colors
          )
        end
      end)

    # Prompt line (replaces minibuffer)
    prompt_text = "> " <> picker.query

    prompt_cmd =
      Protocol.encode_draw(
        prompt_row,
        0,
        String.pad_trailing(prompt_text, viewport.cols),
        fg: highlight_fg,
        bg: prompt_bg
      )

    cursor_col = String.length(prompt_text)
    cursor_pos = {prompt_row, cursor_col}

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    {separator_cmd ++ item_commands ++ [prompt_cmd], cursor_pos}
  end

  @doc "Closes the picker and resets picker-related state."
  @spec close(state()) :: state()
  def close(state) do
    %{state | picker: nil, picker_source: nil, picker_restore: nil}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Preview: temporarily apply the source's on_select for the highlighted item.
  @spec maybe_preview_selection(state()) :: state()
  defp maybe_preview_selection(%{picker: picker, picker_source: source} = state) do
    if Picker.Source.preview?(source) do
      case Picker.selected_item(picker) do
        nil -> state
        item -> source.on_select(item, state)
      end
    else
      state
    end
  end

  # Renders a single picker item row with background, match highlights, and description.
  @spec render_item(
          non_neg_integer(),
          String.t(),
          String.t(),
          boolean(),
          String.t(),
          pos_integer(),
          map()
        ) :: [binary()]
  defp render_item(row, label, desc, is_selected, query, cols, colors) do
    fg = if is_selected, do: colors.highlight_fg, else: colors.text_fg
    row_bg = if is_selected, do: colors.sel_bg, else: colors.bg

    label_text = " " <> label
    avail_for_desc = max(0, cols - String.length(label_text) - 2)

    desc_display =
      if desc != "" and avail_for_desc > 10,
        do: String.slice(desc, -min(avail_for_desc, String.length(desc)), avail_for_desc),
        else: ""

    row_text =
      label_text <>
        String.duplicate(
          " ",
          max(1, cols - String.length(label_text) - String.length(desc_display) - 1)
        ) <> desc_display <> " "

    row_text = String.slice(row_text, 0, cols)

    bg_cmd =
      Protocol.encode_draw(row, 0, String.pad_trailing(row_text, cols),
        fg: fg,
        bg: row_bg,
        bold: is_selected
      )

    highlight_cmds = render_match_highlights(row, label, query, colors.match_fg, row_bg)

    desc_cmds =
      if desc_display != "" do
        desc_start = cols - String.length(desc_display) - 1
        [Protocol.encode_draw(row, desc_start, desc_display, fg: colors.dim_fg, bg: row_bg)]
      else
        []
      end

    [bg_cmd | highlight_cmds] ++ desc_cmds
  end

  # Renders highlighted characters for fuzzy match positions in a picker label.
  @spec render_match_highlights(
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [binary()]
  defp render_match_highlights(row, label, query, match_fg, row_bg) do
    match_positions = Picker.match_positions(label, query)

    label_graphemes = String.graphemes(label)
    label_len = Enum.count(label_graphemes)

    match_positions
    |> Enum.filter(&(&1 < label_len))
    |> Enum.map(fn pos ->
      char = Enum.at(label_graphemes, pos)
      Protocol.encode_draw(row, pos + 1, char, fg: match_fg, bg: row_bg, bold: true)
    end)
  end
end
