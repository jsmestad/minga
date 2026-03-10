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

  alias Minga.Buffer.Unicode
  alias Minga.Editor.DisplayList
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Picker, as: PickerState
  alias Minga.Editor.State.WhichKey, as: WhichKeyState
  alias Minga.Picker
  alias Minga.Port.Protocol

  import Bitwise

  @ctrl Protocol.mod_ctrl()
  @alt Protocol.mod_alt()

  @escape 27
  @enter 13
  @arrow_down 57_353
  @arrow_up 57_352

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Action the GenServer should dispatch after handle_key/3."
  @type action :: {:execute_command, term()}

  defmodule RenderInput do
    @moduledoc """
    Focused input struct for picker rendering.
    Contains only the data needed to render the picker overlay.
    """

    @enforce_keys [:picker_state, :theme_picker, :viewport]
    defstruct [:picker_state, :theme_picker, :viewport]

    @type t :: %__MODULE__{
            picker_state: Minga.Editor.State.Picker.t(),
            theme_picker: map(),
            viewport: Minga.Editor.Viewport.t()
          }
  end

  @doc """
  Opens the picker for the given source module.

  An optional context map can be passed and will be stored in
  `state.picker_ui.context` for the source's `on_select` callback
  to read. Used by `OptionScopeSource` to pass the option name and
  new value through the picker flow.
  """
  @spec open(state(), module(), map() | nil) :: state()
  def open(state, source_module, context \\ nil) do
    items = source_module.candidates(state)

    case items do
      [] ->
        state

      _ ->
        # Use terminal height minus 3 (separator + prompt + at least 1 buffer line visible)
        max_vis = state.viewport.rows - 3
        max_vis = max(5, min(max_vis, state.viewport.rows - 3))
        picker = Picker.new(items, title: source_module.title(), max_visible: max_vis)

        # Clear whichkey state if active
        new_state =
          if state.whichkey.timer do
            %{state | whichkey: WhichKeyState.clear(state.whichkey)}
          else
            state
          end

        %{
          new_state
          | picker_ui: %PickerState{
              picker: picker,
              source: source_module,
              restore: state.buffers.active_index,
              restore_theme: state.theme,
              context: context
            }
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

  # ── Action menu handlers (when C-o menu is open) ────────────────────────────

  # Esc or C-g in action menu → close menu, return to picker
  def handle_key(%{picker_ui: %{action_menu: {_actions, _sel}}} = state, @escape, _mods) do
    put_in(state.picker_ui.action_menu, nil)
  end

  def handle_key(%{picker_ui: %{action_menu: {_actions, _sel}}} = state, ?g, mods)
      when band(mods, @ctrl) != 0 do
    put_in(state.picker_ui.action_menu, nil)
  end

  # Enter in action menu → execute selected action
  def handle_key(
        %{picker_ui: %{action_menu: {actions, sel}, picker: picker, source: source}} = state,
        @enter,
        _mods
      ) do
    case {Enum.at(actions, sel), Picker.selected_item(picker)} do
      {nil, _} ->
        put_in(state.picker_ui.action_menu, nil)

      {_, nil} ->
        put_in(state.picker_ui.action_menu, nil)

      {{_name, action_id}, item} ->
        new_state = close(put_in(state.picker_ui.action_menu, nil))
        source.on_action(action_id, item, new_state)
    end
  end

  # Arrow down / C-j / C-n in action menu → move selection down
  def handle_key(%{picker_ui: %{action_menu: {actions, sel}}} = state, cp, mods)
      when (cp == ?j and band(mods, @ctrl) != 0) or
             (cp == ?n and band(mods, @ctrl) != 0) or
             cp == @arrow_down do
    new_sel = rem(sel + 1, length(actions))
    put_in(state.picker_ui.action_menu, {actions, new_sel})
  end

  # Arrow up / C-k / C-p in action menu → move selection up
  def handle_key(%{picker_ui: %{action_menu: {actions, sel}}} = state, cp, mods)
      when (cp == ?k and band(mods, @ctrl) != 0) or
             (cp == ?p and band(mods, @ctrl) != 0) or
             cp == @arrow_up do
    new_sel = if sel == 0, do: length(actions) - 1, else: sel - 1
    put_in(state.picker_ui.action_menu, {actions, new_sel})
  end

  # Ignore all other keys while action menu is open
  def handle_key(%{picker_ui: %{action_menu: {_actions, _sel}}} = state, _cp, _mods), do: state

  # ── Normal picker handlers ─────────────────────────────────────────────────

  def handle_key(%{picker_ui: %{source: source}} = state, @escape, _mods) do
    new_state = source.on_cancel(state)
    close(new_state)
  end

  # C-g → cancel (Emacs-style)
  def handle_key(%{picker_ui: %{source: source}} = state, ?g, mods) when band(mods, @ctrl) != 0 do
    new_state = source.on_cancel(state)
    close(new_state)
  end

  def handle_key(%{picker_ui: %{picker: picker, source: source}} = state, @enter, _mods) do
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

  # C-j, C-n, or arrow down → move selection down
  def handle_key(%{picker_ui: %{picker: picker} = pui} = state, cp, mods)
      when (cp == ?j and band(mods, @ctrl) != 0) or
             (cp == ?n and band(mods, @ctrl) != 0) or
             cp == @arrow_down do
    new_picker = Picker.move_down(picker)
    state = %{state | picker_ui: %{pui | picker: new_picker}}
    maybe_preview_selection(state)
  end

  # C-k, C-p, or arrow up → move selection up
  def handle_key(%{picker_ui: %{picker: picker} = pui} = state, cp, mods)
      when (cp == ?k and band(mods, @ctrl) != 0) or
             (cp == ?p and band(mods, @ctrl) != 0) or
             cp == @arrow_up do
    new_picker = Picker.move_up(picker)
    state = %{state | picker_ui: %{pui | picker: new_picker}}
    maybe_preview_selection(state)
  end

  # C-v → page down
  def handle_key(%{picker_ui: %{picker: picker} = pui} = state, ?v, mods)
      when band(mods, @ctrl) != 0 do
    new_picker = Picker.page_down(picker)
    state = %{state | picker_ui: %{pui | picker: new_picker}}
    maybe_preview_selection(state)
  end

  # M-v (Alt+v) → page up
  def handle_key(%{picker_ui: %{picker: picker} = pui} = state, ?v, mods)
      when band(mods, @alt) != 0 do
    new_picker = Picker.page_up(picker)
    state = %{state | picker_ui: %{pui | picker: new_picker}}
    maybe_preview_selection(state)
  end

  # C-o → open action menu for the selected item
  def handle_key(%{picker_ui: %{picker: picker, source: source}} = state, ?o, mods)
      when band(mods, @ctrl) != 0 do
    case Picker.selected_item(picker) do
      nil ->
        state

      item ->
        actions = Picker.Source.actions(source, item)

        case actions do
          [] -> state
          actions -> put_in(state.picker_ui.action_menu, {actions, 0})
        end
    end
  end

  # Backspace
  def handle_key(%{picker_ui: %{picker: picker} = pui} = state, cp, _mods)
      when cp in [8, 127] do
    new_picker = Picker.backspace(picker)
    state = %{state | picker_ui: %{pui | picker: new_picker}}
    maybe_preview_selection(state)
  end

  # Printable characters → filter
  def handle_key(%{picker_ui: %{picker: picker} = pui} = state, codepoint, 0)
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
        state = %{state | picker_ui: %{pui | picker: new_picker}}
        maybe_preview_selection(state)
    end
  end

  # Ignore all other keys
  def handle_key(state, _cp, _mods), do: state

  @doc """
  Renders the picker overlay. Returns `{draws, cursor_pos | nil}`.

  This is the focused version that takes a RenderInput struct.
  """
  @spec render(RenderInput.t()) ::
          {[DisplayList.draw()], {non_neg_integer(), non_neg_integer()} | nil}
  def render(%RenderInput{picker_state: %{picker: nil}}), do: {[], nil}

  def render(%RenderInput{
        picker_state: %{picker: picker, action_menu: action_menu},
        theme_picker: pc,
        viewport: viewport
      }) do
    {visible, selected_offset} = Picker.visible_items(picker)
    item_count = length(visible)

    # Layout: items grow upward from row N-2, prompt on row N-1
    prompt_row = viewport.rows - 1
    separator_row = prompt_row - item_count - 1
    first_item_row = separator_row + 1

    # Theme colors
    bg = pc.bg
    sel_bg = pc.sel_bg
    prompt_bg = pc.prompt_bg
    dim_fg = pc.dim_fg
    text_fg = pc.text_fg
    highlight_fg = pc.highlight_fg

    # Separator line
    title = picker.title
    filter_info = "#{Picker.count(picker)}/#{Picker.total(picker)}"

    sep_text =
      " #{title} " <>
        String.duplicate(
          "─",
          max(
            0,
            viewport.cols - Unicode.display_width(title) - Unicode.display_width(filter_info) - 4
          )
        ) <> " #{filter_info} "

    separator_cmd =
      if separator_row >= 0 do
        [
          DisplayList.draw(separator_row, 0, String.pad_trailing(sep_text, viewport.cols),
            fg: dim_fg,
            bg: bg
          )
        ]
      else
        []
      end

    match_fg = pc.match_fg

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
      DisplayList.draw(
        prompt_row,
        0,
        String.pad_trailing(prompt_text, viewport.cols),
        fg: highlight_fg,
        bg: prompt_bg
      )

    cursor_col = Unicode.display_width(prompt_text)
    cursor_pos = {prompt_row, cursor_col}

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    all_cmds = separator_cmd ++ item_commands ++ [prompt_cmd]

    # Render action menu overlay if open
    action_cmds =
      render_action_menu(
        %{picker_state: %{action_menu: action_menu}, theme_picker: pc, viewport: viewport},
        first_item_row,
        selected_offset
      )

    {all_cmds ++ action_cmds, cursor_pos}
  end

  @doc """
  Renders the picker overlay. Returns `{draws, cursor_pos | nil}`.

  Legacy wrapper that extracts RenderInput from full editor state.
  """
  @spec render(state(), term()) ::
          {[DisplayList.draw()], {non_neg_integer(), non_neg_integer()} | nil}
  def render(state, viewport) do
    input = %RenderInput{
      picker_state: state.picker_ui,
      theme_picker: state.theme.picker,
      viewport: viewport
    }

    render(input)
  end

  @doc "Closes the picker and resets picker-related state."
  @spec close(state()) :: state()
  def close(state) do
    %{state | picker_ui: %PickerState{}}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Preview: temporarily apply the source's on_select for the highlighted item.
  @spec maybe_preview_selection(state()) :: state()
  defp maybe_preview_selection(%{picker_ui: %{picker: picker, source: source}} = state) do
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
        ) :: [DisplayList.draw()]
  defp render_item(row, label, desc, is_selected, query, cols, colors) do
    fg = if is_selected, do: colors.highlight_fg, else: colors.text_fg
    row_bg = if is_selected, do: colors.sel_bg, else: colors.bg

    label_text = " " <> label
    avail_for_desc = max(0, cols - Unicode.display_width(label_text) - 2)

    desc_display =
      if desc != "" and avail_for_desc > 10,
        do: String.slice(desc, -min(avail_for_desc, String.length(desc)), avail_for_desc),
        else: ""

    row_text =
      label_text <>
        String.duplicate(
          " ",
          max(
            1,
            cols - Unicode.display_width(label_text) - Unicode.display_width(desc_display) - 1
          )
        ) <> desc_display <> " "

    row_text = String.slice(row_text, 0, cols)

    bg_cmd =
      DisplayList.draw(row, 0, String.pad_trailing(row_text, cols),
        fg: fg,
        bg: row_bg,
        bold: is_selected
      )

    highlight_cmds = render_match_highlights(row, label, query, colors.match_fg, row_bg)

    desc_cmds =
      if desc_display != "" do
        desc_start = cols - Unicode.display_width(desc_display) - 1
        [DisplayList.draw(row, desc_start, desc_display, fg: colors.dim_fg, bg: row_bg)]
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
        ) :: [DisplayList.draw()]
  defp render_match_highlights(row, label, query, match_fg, row_bg) do
    match_positions = Picker.match_positions(label, query)

    label_graphemes = String.graphemes(label)
    label_len = Enum.count(label_graphemes)

    match_positions
    |> Enum.filter(&(&1 < label_len))
    |> Enum.map(fn pos ->
      char = Enum.at(label_graphemes, pos)
      DisplayList.draw(row, pos + 1, char, fg: match_fg, bg: row_bg, bold: true)
    end)
  end

  # Renders the C-o action menu popup overlay.
  @spec render_action_menu(map(), non_neg_integer(), non_neg_integer()) :: [DisplayList.draw()]
  defp render_action_menu(
         %{picker_state: %{action_menu: nil}},
         _first_item_row,
         _sel_offset
       ) do
    []
  end

  defp render_action_menu(
         %{
           picker_state: %{action_menu: {actions, menu_sel}},
           theme_picker: pc,
           viewport: viewport
         },
         first_item_row,
         selected_offset
       ) do
    # Position the action menu popup next to the selected picker item
    menu_row_start = first_item_row + selected_offset
    menu_col = div(viewport.cols, 3)
    menu_width = min(30, viewport.cols - menu_col - 2)
    border_fg = pc.border_fg
    menu_bg = pc.menu_bg
    menu_fg = pc.menu_fg
    menu_sel_bg = pc.menu_sel_bg
    menu_sel_fg = pc.menu_sel_fg

    # Header
    header_text = String.pad_trailing(" Actions", menu_width)
    header_row = menu_row_start

    header_cmd =
      if header_row >= 0 and header_row < viewport.rows do
        [
          DisplayList.draw(header_row, menu_col, header_text,
            fg: border_fg,
            bg: menu_bg,
            bold: true
          )
        ]
      else
        []
      end

    # Action items
    menu_colors = %{fg: menu_fg, sel_fg: menu_sel_fg, bg: menu_bg, sel_bg: menu_sel_bg}

    action_cmds =
      actions
      |> Enum.with_index()
      |> Enum.flat_map(fn {{name, _id}, idx} ->
        render_action_item(
          header_row + idx + 1,
          menu_col,
          menu_width,
          name,
          idx == menu_sel,
          viewport.rows,
          menu_colors
        )
      end)

    header_cmd ++ action_cmds
  end

  @spec render_action_item(
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          boolean(),
          non_neg_integer(),
          map()
        ) :: [DisplayList.draw()]
  defp render_action_item(row, _col, _width, _name, _is_sel, max_rows, _colors)
       when row < 0 or row >= max_rows do
    []
  end

  defp render_action_item(row, col, width, name, is_sel, _max_rows, colors) do
    fg = if is_sel, do: colors.sel_fg, else: colors.fg
    bg = if is_sel, do: colors.sel_bg, else: colors.bg
    text = String.pad_trailing(" #{name}", width)

    [DisplayList.draw(row, col, text, fg: fg, bg: bg, bold: is_sel)]
  end
end
