defmodule MingaEditor.PickerUI do
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

  alias Minga.Core.Face
  alias Minga.Core.Unicode
  alias MingaEditor.DisplayList
  alias MingaEditor.FloatingWindow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.WhichKey, as: WhichKeyState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  import Bitwise

  @ctrl MingaEditor.Input.mod_ctrl()
  @alt MingaEditor.Input.mod_alt()

  @escape 27
  @enter 13
  @arrow_down 57_353
  @arrow_up 57_352

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Action the GenServer should dispatch after handle_key/3."
  @type action :: {:execute_command, term()}

  # Mode-switching prefix map: first character → source module.
  # When a prefix character is typed as the first query char in a switchable
  # source (file picker, recent files), the picker swaps to the mapped source
  # and strips the prefix from the fuzzy query.
  # Git log no longer uses a single-letter switch, so fuzzy search input like
  # "fix" stays in the query instead of changing picker modes.
  @file_mode_prefixes %{
    ">" => MingaEditor.UI.Picker.CommandSource,
    "#" => MingaEditor.UI.Picker.ProjectSearchSource,
    "@" => MingaEditor.UI.Picker.BufferSource
  }

  @mode_prefixes %{
    MingaEditor.UI.Picker.FileSource => @file_mode_prefixes,
    MingaEditor.UI.Picker.RecentFileSource => @file_mode_prefixes
  }

  defmodule RenderInput do
    @moduledoc """
    Focused input struct for picker rendering.
    Contains only the data needed to render the picker overlay.
    """

    @enforce_keys [:picker_state, :theme_picker, :viewport]
    defstruct [:picker_state, :theme_picker, :viewport]

    @type t :: %__MODULE__{
            picker_state: MingaEditor.State.Picker.t(),
            theme_picker: map(),
            viewport: MingaEditor.Viewport.t()
          }
  end

  @doc """
  Opens the picker for the given source module.

  An optional context map can be passed; it is threaded into the
  `Context` struct passed to `candidates/1` so sources can use it to
  build items. Sources that need the context inside `on_select/2` must
  embed it in each `Item.id` at candidate-build time, because the picker
  is closed (modal reset to `:none`) before `on_select/2` runs. See
  `OptionScopeSource` for the canonical pattern.
  """
  @spec open(state(), module(), map() | nil) :: state()
  def open(state, source_module, context \\ nil) do
    if MingaEditor.UI.Picker.Source.async?(source_module) do
      open_async(state, source_module, context)
    else
      open_sync(state, source_module, context)
    end
  end

  @spec open_sync(state(), module(), map() | nil) :: state()
  defp open_sync(state, source_module, context) do
    ctx = Context.from_editor_state(state, context)
    items = source_module.candidates(ctx)

    case items do
      [] ->
        state

      _ ->
        open_with_items(state, source_module, items, context)
    end
  end

  @spec open_async(state(), module(), map() | nil) :: state()
  defp open_async(state, source_module, context) do
    max_vis = max(state.terminal_viewport.rows - 3, 5)
    picker = Picker.new([], title: source_module.title(), max_visible: max_vis)

    new_state = clear_whichkey(state)
    layout = MingaEditor.UI.Picker.Source.layout(source_module)

    picker_state = %PickerState{
      picker: picker,
      source: source_module,
      restore: state.workspace.buffers.active_index,
      restore_theme: state.theme,
      context: context,
      layout: layout,
      load_status: :loading
    }

    new_state = ModalOverlay.open(new_state, :picker, PickerPayload.new(picker_state))

    send(
      self(),
      {:picker_fetch_candidates, source_module, Context.from_editor_state(state, context)}
    )

    new_state
  end

  @spec open_with_items(state(), module(), [Picker.item()], map() | nil) :: state()
  defp open_with_items(state, source_module, items, context) do
    max_vis = max(state.terminal_viewport.rows - 3, 5)
    picker = Picker.new(items, title: source_module.title(), max_visible: max_vis)

    new_state = clear_whichkey(state)
    layout = MingaEditor.UI.Picker.Source.layout(source_module)

    picker_state = %PickerState{
      picker: picker,
      source: source_module,
      restore: state.workspace.buffers.active_index,
      restore_theme: state.theme,
      context: context,
      layout: layout
    }

    ModalOverlay.open(new_state, :picker, PickerPayload.new(picker_state))
  end

  @spec clear_whichkey(state()) :: state()
  defp clear_whichkey(state) do
    if EditorState.whichkey(state).timer do
      EditorState.set_whichkey(state, WhichKeyState.clear(EditorState.whichkey(state)))
    else
      state
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
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{action_menu: {_actions, _sel}}}}}} =
          state,
        @escape,
        _mods
      ) do
    update_picker(state, &%{&1 | action_menu: nil})
  end

  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{action_menu: {_actions, _sel}}}}}} =
          state,
        ?g,
        mods
      )
      when band(mods, @ctrl) != 0 do
    update_picker(state, &%{&1 | action_menu: nil})
  end

  # Enter in action menu → execute selected action
  def handle_key(
        %{
          shell_state: %{
            modal:
              {:picker,
               %{picker_ui: %{action_menu: {actions, sel}, picker: picker, source: source}}}
          }
        } = state,
        @enter,
        _mods
      ) do
    case {Enum.at(actions, sel), Picker.selected_item(picker)} do
      {nil, _} ->
        update_picker(state, &%{&1 | action_menu: nil})

      {_, nil} ->
        update_picker(state, &%{&1 | action_menu: nil})

      {{_name, action_id}, item} ->
        state
        |> update_picker(&%{&1 | action_menu: nil})
        |> run_source_action_and_close(source, action_id, item)
    end
  end

  # Arrow down / C-j / C-n in action menu → move selection down
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{action_menu: {actions, sel}}}}}} = state,
        cp,
        mods
      )
      when (cp == ?j and band(mods, @ctrl) != 0) or
             (cp == ?n and band(mods, @ctrl) != 0) or
             cp == @arrow_down do
    new_sel = rem(sel + 1, length(actions))
    update_picker(state, &%{&1 | action_menu: {actions, new_sel}})
  end

  # Arrow up / C-k / C-p in action menu → move selection up
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{action_menu: {actions, sel}}}}}} = state,
        cp,
        mods
      )
      when (cp == ?k and band(mods, @ctrl) != 0) or
             (cp == ?p and band(mods, @ctrl) != 0) or
             cp == @arrow_up do
    new_sel = if sel == 0, do: length(actions) - 1, else: sel - 1
    update_picker(state, &%{&1 | action_menu: {actions, new_sel}})
  end

  # Ignore all other keys while action menu is open
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{action_menu: {_actions, _sel}}}}}} =
          state,
        _cp,
        _mods
      ),
      do: state

  # ── Normal picker handlers ─────────────────────────────────────────────────

  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{source: source}}}}} = state,
        @escape,
        _mods
      ) do
    new_state = source.on_cancel(state)
    close(new_state)
  end

  # C-g → cancel (Emacs-style)
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{source: source}}}}} = state,
        ?g,
        mods
      )
      when band(mods, @ctrl) != 0 do
    new_state = source.on_cancel(state)
    close(new_state)
  end

  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}} =
          state,
        @enter,
        _mods
      ) do
    case Picker.selected_item(picker) do
      nil -> close(state)
      item -> select_item(state, picker, item, source)
    end
  end

  # C-j, C-n, or arrow down → move selection down
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}} = state,
        cp,
        mods
      )
      when (cp == ?j and band(mods, @ctrl) != 0) or
             (cp == ?n and band(mods, @ctrl) != 0) or
             cp == @arrow_down do
    new_picker = Picker.move_down(picker)
    state = update_picker(state, &%{&1 | picker: new_picker})
    maybe_preview_selection(state)
  end

  # C-k, C-p, or arrow up → move selection up
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}} = state,
        cp,
        mods
      )
      when (cp == ?k and band(mods, @ctrl) != 0) or
             (cp == ?p and band(mods, @ctrl) != 0) or
             cp == @arrow_up do
    new_picker = Picker.move_up(picker)
    state = update_picker(state, &%{&1 | picker: new_picker})
    maybe_preview_selection(state)
  end

  # C-v → page down
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}} = state,
        ?v,
        mods
      )
      when band(mods, @ctrl) != 0 do
    new_picker = Picker.page_down(picker)
    state = update_picker(state, &%{&1 | picker: new_picker})
    maybe_preview_selection(state)
  end

  # M-v (Alt+v) → page up
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}} = state,
        ?v,
        mods
      )
      when band(mods, @alt) != 0 do
    new_picker = Picker.page_up(picker)
    state = update_picker(state, &%{&1 | picker: new_picker})
    maybe_preview_selection(state)
  end

  # Tab → toggle multi-select mark on current item, then move down
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}} = state,
        9,
        _mods
      ) do
    new_picker = picker |> Picker.toggle_mark() |> Picker.move_down()
    update_picker(state, &%{&1 | picker: new_picker})
  end

  # C-o → open action menu for the selected item
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}} =
          state,
        ?o,
        mods
      )
      when band(mods, @ctrl) != 0 do
    case Picker.selected_item(picker) do
      nil ->
        state

      item ->
        actions = action_menu_actions(source, picker, item)

        case actions do
          [] -> state
          actions -> update_picker(state, &%{&1 | action_menu: {actions, 0}})
        end
    end
  end

  # C-d → branch picker delete flow only. Keeps printable `d` available for
  # normal picker filtering, including sources that define alternative delete
  # actions for other purposes.
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}} =
          state,
        ?d,
        mods
      )
      when band(mods, @ctrl) != 0 and
             source == :"Elixir.MingaGitPorcelain.UI.Picker.GitBranchSource" do
    case Picker.selected_item(picker) do
      %Item{id: {:branch, _name, _current?, true}} ->
        state

      %Item{id: {:branch, _name, true, false}} = item ->
        run_source_action_and_close(state, source, :delete, item)

      %Item{id: {:branch, _name, false, false}} = item ->
        run_source_action_and_close(state, source, :delete, item)

      _other ->
        state
    end
  end

  # Backspace (with mode-switch detection: if query becomes empty and we're in a switched mode, switch back)
  def handle_key(
        %{
          shell_state: %{
            modal:
              {:picker,
               %{picker_ui: %{picker: picker, mode_prefix: prefix, original_source: orig}}}
          }
        } = state,
        cp,
        _mods
      )
      when cp in [8, 127] do
    new_picker = Picker.backspace(picker)

    # If query is now empty and we had mode-switched, switch back to original source
    if new_picker.query == "" and prefix != "" and orig != nil do
      switch_back_to_original(state)
    else
      state = update_picker(state, &%{&1 | picker: new_picker})
      maybe_preview_selection(state)
    end
  end

  # Printable characters → filter (with mode-switch detection)
  def handle_key(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}} = state,
        codepoint,
        0
      )
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
        type_printable_char(state, picker, c)
    end
  end

  # Ignore all other keys
  def handle_key(state, _cp, _mods), do: state

  @spec run_source_action_and_close(EditorState.t(), module(), term(), Picker.item()) ::
          EditorState.t()
  defp run_source_action_and_close(state, source, action_id, item) do
    new_state = close(state)
    run_action(source, action_id, item, new_state)
  end

  @spec type_printable_char(EditorState.t(), Picker.t(), String.t()) :: EditorState.t()
  defp type_printable_char(state, picker, char) do
    case maybe_switch_mode(state, char, picker.query) do
      {:switched, new_state} ->
        new_state

      :no_switch ->
        new_picker = Picker.type_char(picker, char)
        state = update_picker(state, &%{&1 | picker: new_picker})
        maybe_preview_selection(state)
    end
  end

  @spec select_item(EditorState.t(), Picker.t(), Picker.item(), module()) ::
          EditorState.t() | {EditorState.t(), {:execute_command, atom()}}
  defp select_item(state, picker, item, source) do
    if bulk_select?(source, picker) do
      run_bulk_select_and_close(state, picker, source)
    else
      select_single_item(state, item, source)
    end
  end

  @spec select_single_item(EditorState.t(), Picker.item(), module()) ::
          EditorState.t() | {EditorState.t(), {:execute_command, atom()}}
  defp select_single_item(state, item, source) do
    if Picker.Source.keep_open_on_select?(source) do
      new_state = source.on_select(item, state)
      refresh_items(new_state)
    else
      select_item_and_close(state, item, source)
    end
  end

  @spec select_item_and_close(EditorState.t(), Picker.item(), module()) ::
          EditorState.t() | {EditorState.t(), {:execute_command, atom()}}
  defp select_item_and_close(state, item, source) do
    if Picker.Source.live_preview?(source) and previewed?(state) do
      promote_previewed_buffer(state)
    else
      run_select_and_close(state, item, source)
    end
  end

  # Preview loaded a different buffer into the window. Close the picker and
  # promote the previewed buffer to a proper new tab via add_buffer(:open).
  # The tab bar was never modified by preview, so on_buffer_added will create
  # a fresh tab.
  @spec promote_previewed_buffer(EditorState.t()) :: EditorState.t()
  defp promote_previewed_buffer(state) do
    previewed_pid = state.workspace.buffers.active

    state =
      state
      |> restore_picker_origin()
      |> close()
      |> EditorState.add_buffer(previewed_pid, context: :open)

    record_previewed_buffer_access(previewed_pid)
    state
  end

  @spec record_previewed_buffer_access(pid()) :: :ok
  defp record_previewed_buffer_access(buffer) when is_pid(buffer) do
    case Minga.Buffer.file_path(buffer) do
      path when is_binary(path) -> Minga.Project.record_file(path)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  @spec run_select_and_close(EditorState.t(), Picker.item(), module()) ::
          EditorState.t() | {EditorState.t(), {:execute_command, atom()}}
  defp run_select_and_close(state, item, source) do
    new_state = close(state)
    new_state = source.on_select(item, new_state)

    case Map.get(new_state, :pending_command) do
      nil ->
        new_state

      cmd ->
        record_command_execution(source, cmd)
        {Map.delete(new_state, :pending_command), {:execute_command, cmd}}
    end
  end

  @spec run_bulk_select_and_close(EditorState.t(), Picker.t(), module()) :: EditorState.t()
  defp run_bulk_select_and_close(state, picker, source) do
    items = Picker.marked_items(picker)

    state
    |> restore_picker_origin()
    |> close()
    |> then(&Picker.Source.bulk_select(source, items, &1))
  end

  @spec bulk_select?(module(), Picker.t()) :: boolean()
  defp bulk_select?(source, picker) do
    Picker.has_marks?(picker) and Picker.Source.has_bulk_select?(source)
  end

  @spec action_menu_actions(module(), Picker.t(), Picker.item()) :: [Picker.Source.action_entry()]
  defp action_menu_actions(source, picker, item) do
    if Picker.has_marks?(picker) do
      bulk_action_menu_actions(source, Picker.marked_items(picker), item)
    else
      Picker.Source.actions(source, item)
    end
  end

  @spec bulk_action_menu_actions(module(), [Picker.item()], Picker.item()) :: [
          Picker.Source.action_entry()
        ]
  defp bulk_action_menu_actions(source, items, item) do
    case Picker.Source.bulk_actions(source, items) do
      [] ->
        Picker.Source.actions(source, item)

      actions ->
        Enum.map(actions, fn {name, action_id} -> {name, {:bulk, action_id, items}} end)
    end
  end

  @spec run_action(module(), term(), Picker.item(), EditorState.t()) :: EditorState.t()
  defp run_action(source, {:bulk, action_id, items}, _item, state) do
    Picker.Source.on_bulk_action(source, action_id, items, state)
  end

  defp run_action(source, action_id, item, state) do
    source.on_action(action_id, item, state)
  end

  @spec record_command_execution(module(), term()) :: :ok
  defp record_command_execution(MingaEditor.UI.Picker.CommandSource, command_name)
       when is_atom(command_name) do
    Minga.Project.record_command(command_name)
  catch
    :exit, _ -> :ok
  end

  defp record_command_execution(_source, _command_name), do: :ok

  @doc """
  Renders the picker overlay. Returns `{draws, cursor_pos | nil}`.

  This is the focused version that takes a RenderInput struct.
  """
  @spec render(RenderInput.t()) ::
          {[DisplayList.draw()], {non_neg_integer(), non_neg_integer()} | nil}
  def render(%RenderInput{picker_state: %{picker: nil}}), do: {[], nil}

  def render(%RenderInput{picker_state: %{layout: :centered}} = input) do
    render_centered(input)
  end

  def render(%RenderInput{
        picker_state: %{picker: picker, action_menu: action_menu} = picker_state,
        theme_picker: pc,
        viewport: viewport
      }) do
    # Clamp so item rows + separator + prompt never exceed viewport height.
    row_budget = max(viewport.rows - 3, 1)
    {visible, selected_offset, item_rows} = bottom_visible_items(picker, row_budget)
    selected_row_offset = row_offset_for_visible_index(visible, selected_offset)

    status_message = load_status_message(picker_state, visible, picker.query)
    item_rows = if status_message, do: 1, else: item_rows

    # Layout: item rows grow upward from row N-2, prompt on row N-1
    prompt_row = viewport.rows - 1
    separator_row = prompt_row - item_rows - 1
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
    filter_info = picker_filter_info(picker)
    sep_text = picker_top_rule(title, filter_info, viewport.cols)

    separator_cmd =
      if separator_row >= 0 do
        [
          DisplayList.draw(
            separator_row,
            0,
            sep_text,
            Face.new(fg: pc.border_fg, bg: bg, bold: true)
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
      match_fg: match_fg,
      border_fg: pc.border_fg
    }

    item_commands =
      if status_message do
        [
          DisplayList.draw(
            first_item_row,
            0,
            String.pad_trailing("  #{status_message}", viewport.cols),
            Face.new(fg: dim_fg, bg: bg)
          )
        ]
      else
        {cmds, _row_offset} =
          visible
          |> Enum.with_index()
          |> Enum.map_reduce(0, fn {{item, rows_used}, idx}, row_offset ->
            row = first_item_row + row_offset

            commands =
              render_visible_item(
                row,
                rows_used,
                item,
                idx == selected_offset,
                picker.query,
                viewport,
                picker_colors
              )

            {commands, row_offset + rows_used}
          end)

        List.flatten(cmds)
      end

    # Prompt line (replaces minibuffer)
    prompt_text = prompt_prefix(picker_state) <> picker.query

    prompt_cmds =
      render_prompt_line(
        prompt_row,
        0,
        viewport.cols,
        prompt_text,
        picker_state,
        prompt_bg,
        highlight_fg,
        match_fg
      )

    cursor_col = Unicode.display_width(prompt_text)
    cursor_pos = {prompt_row, cursor_col}

    all_cmds = separator_cmd ++ item_commands ++ prompt_cmds

    # Render action menu overlay if open
    action_cmds =
      render_action_menu(
        %{picker_state: %{action_menu: action_menu}, theme_picker: pc, viewport: viewport},
        first_item_row,
        selected_row_offset
      )

    {all_cmds ++ action_cmds, cursor_pos}
  end

  @spec picker_filter_info(Picker.t()) :: String.t()
  defp picker_filter_info(picker) do
    base = "#{Picker.count(picker)}/#{Picker.total(picker)}"

    case Picker.marked_count(picker) do
      0 -> base
      count -> "#{base} (#{count} marked)"
    end
  end

  @spec picker_top_rule(String.t(), String.t(), pos_integer()) :: String.t()
  defp picker_top_rule(_title, _filter_info, 1), do: "╭"

  defp picker_top_rule(title, filter_info, cols) do
    left = "╭─ #{title} "
    right = " #{filter_info} ╮"

    rule =
      left <>
        String.duplicate(
          "─",
          max(0, cols - Unicode.display_width(left) - Unicode.display_width(right))
        ) <> right

    rule
    |> Unicode.truncate_display_width(cols)
    |> Unicode.pad_display_trailing(cols)
  end

  @doc """
  Renders the picker overlay. Returns `{draws, cursor_pos | nil}`.

  Legacy wrapper that extracts RenderInput from full editor state.
  """
  @spec render(state(), term()) ::
          {[DisplayList.draw()], {non_neg_integer(), non_neg_integer()} | nil}
  def render(state, viewport) do
    picker_state =
      case state.shell_state.modal do
        {:picker, %{picker_ui: pui}} -> pui
        _ -> %PickerState{}
      end

    input = %RenderInput{
      picker_state: picker_state,
      theme_picker: state.theme.picker,
      viewport: viewport
    }

    render(input)
  end

  @spec prompt_prefix(PickerState.t()) :: String.t()
  defp prompt_prefix(%PickerState{mode_prefix: prefix}) when is_binary(prefix) and prefix != "" do
    "[#{prefix}] "
  end

  defp prompt_prefix(%PickerState{}), do: "> "

  @spec render_prompt_line(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          PickerState.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp render_prompt_line(row, col, width, text, picker_state, bg, fg, indicator_fg) do
    base_draw =
      DisplayList.draw(row, col, String.pad_trailing(text, width), Face.new(fg: fg, bg: bg))

    [base_draw | render_mode_indicator(row, col, picker_state, bg, indicator_fg)]
  end

  @spec render_mode_indicator(
          non_neg_integer(),
          non_neg_integer(),
          PickerState.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp render_mode_indicator(row, col, %PickerState{mode_prefix: prefix}, bg, fg)
       when is_binary(prefix) and prefix != "" do
    [DisplayList.draw(row, col, "[#{prefix}]", Face.new(fg: fg, bg: bg, bold: true))]
  end

  defp render_mode_indicator(_row, _col, %PickerState{}, _bg, _fg), do: []

  @doc "Closes the picker and resets picker-related state."
  @spec close(state()) :: state()
  def close(state) do
    state
    |> EditorState.set_buffer_add_context(:open)
    |> ModalOverlay.dismiss()
  end

  @doc """
  Refreshes the picker items from the source while preserving the query
  and selection position. Used by keep-open pickers (e.g., tool manager)
  to update item status after an action.
  """
  @spec refresh_items(state()) :: state()
  def refresh_items(%{shell_state: %{modal: {:picker, %{picker_ui: %{picker: nil}}}}} = state),
    do: state

  def refresh_items(
        %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}} =
          state
      ) do
    ctx = Context.from_editor_state(state)
    items = source.candidates(ctx)
    refreshed = %{picker | items: items}
    refreshed = Picker.filter(refreshed, picker.query)

    # Clamp selection to new item count
    max_sel = max(length(refreshed.filtered) - 1, 0)
    refreshed = %{refreshed | selected: min(picker.selected, max_sel)}

    update_picker(state, &%{&1 | picker: refreshed})
  end

  @doc """
  Applies `fun` to the current PickerState inside the modal and writes back
  via ModalOverlay.transition, keeping the modal sum type and consistency
  check in sync.

  Public so that `Input.Picker` (mouse handler) can update scroll position
  without going through the full key-handling path.
  """
  @spec update_picker(state(), (PickerState.t() -> PickerState.t())) :: state()
  def update_picker(state, fun) do
    {:picker, payload} = state.shell_state.modal
    new_pui = fun.(payload.picker_ui)
    ModalOverlay.transition(state, :picker, PickerPayload.put_picker_ui(payload, new_pui))
  end

  # ── Centered (floating) layout ───────────────────────────────────────────────

  @spec render_centered(RenderInput.t()) ::
          {[DisplayList.draw()], {non_neg_integer(), non_neg_integer()} | nil}
  defp render_centered(%RenderInput{
         picker_state: %{picker: picker} = picker_state,
         theme_picker: pc,
         viewport: viewport
       }) do
    item_capacity = centered_item_capacity(viewport.rows)
    {visible, selected_offset} = Picker.visible_items(picker, item_capacity)

    status_message = load_status_message(picker_state, visible, picker.query)

    # Compute float window dimensions
    float_width = {:percent, 60}
    float_height_rows = centered_float_height(visible, viewport, status_message != nil)
    float_height = {:rows, float_height_rows}

    backdrop = Minga.Config.Options.get(:picker_backdrop)

    popup_theme = %{
      fg: pc.text_fg,
      bg: pc.bg,
      border_fg: pc.dim_fg,
      title_fg: pc.highlight_fg,
      backdrop_color: 0x111111
    }

    spec = %FloatingWindow.Spec{
      title: picker.title,
      footer: "#{Picker.count(picker)}/#{Picker.total(picker)}",
      width: float_width,
      height: float_height,
      border: :rounded,
      theme: popup_theme,
      viewport: {viewport.rows, viewport.cols},
      backdrop: backdrop
    }

    {interior_h, interior_w} = FloatingWindow.interior_size(spec)

    # Reserve 1 row for the prompt at the bottom of the interior
    items_h = max(interior_h - 1, 0)

    # Build content draws (relative to interior origin)
    item_draws =
      if status_message do
        [
          DisplayList.draw(
            0,
            0,
            String.pad_trailing("  #{status_message}", interior_w),
            Face.new(fg: pc.dim_fg, bg: pc.bg)
          )
        ]
      else
        render_centered_items(visible, items_h, selected_offset, picker.query, interior_w, pc)
      end

    # Prompt at the bottom of the interior
    prompt_text = prompt_prefix(picker_state) <> picker.query

    prompt_draws =
      render_prompt_line(
        interior_h - 1,
        0,
        interior_w,
        prompt_text,
        picker_state,
        pc.prompt_bg,
        pc.highlight_fg,
        pc.match_fg
      )

    content = item_draws ++ prompt_draws
    spec = %{spec | content: content}

    draws = FloatingWindow.render(spec)

    # Compute absolute cursor position inside the floating window
    {vp_rows, vp_cols} = {viewport.rows, viewport.cols}
    box_w = resolve_percent(60, vp_cols)
    box_h = min(float_height_rows, vp_rows)
    box_row = max(div(vp_rows - box_h, 2), 0)
    box_col = max(div(vp_cols - box_w, 2), 0)
    # Interior starts at box + 1 (border inset)
    cursor_row = box_row + 1 + (interior_h - 1)
    cursor_col = box_col + 1 + Unicode.display_width(prompt_text)
    cursor_pos = {cursor_row, cursor_col}

    {draws, cursor_pos}
  end

  @spec render_centered_items(
          [Picker.item()],
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          pos_integer(),
          map()
        ) :: [DisplayList.draw()]
  defp render_centered_items(visible, items_h, selected_offset, query, interior_w, pc) do
    taken = Enum.take(visible, items_h)
    has_active = Enum.any?(taken, & &1.active)

    taken
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      active_val = if(has_active, do: item.active, else: nil)

      render_centered_item(
        %{row: idx, item: item, selected: idx == selected_offset, active: active_val},
        query,
        interior_w,
        pc
      )
    end)
  end

  @spec render_centered_item(map(), String.t(), pos_integer(), map()) :: [DisplayList.draw()]
  defp render_centered_item(
         %{row: row, item: item, selected: selected, active: active},
         query,
         width,
         pc
       ) do
    bg = pc.bg
    fg = if selected, do: pc.highlight_fg, else: pc.text_fg

    desc_text =
      case item.description do
        nil -> ""
        "" -> ""
        d -> " " <> d
      end

    # Active indicator occupies 2 chars (bullet + space) when any item is active.
    {active_prefix, active_draws, label_col} = active_indicator(row, active, pc, bg)

    # Pad the entire row with a leading gutter so the selected rail does not cover text.
    full_text = "  " <> active_prefix <> item.label <> desc_text
    padded = String.pad_trailing(full_text, width)

    # Base draw (full row background)
    base = [DisplayList.draw(row, 0, padded, Face.new(fg: pc.dim_fg, bg: bg))]

    # Label (brighter text)
    label_draw = [DisplayList.draw(row, label_col, item.label, Face.new(fg: fg, bg: bg))]

    # Icon color overlay
    icon_draws = render_icon_color(row, item.icon_color, bg, item.label, label_col)

    rail_draws = render_selected_rail(row, 0, selected, pc.highlight_fg, bg)

    # Highlight matching characters in the label
    match_draws = render_match_highlights_at(row, item.label, query, pc.match_fg, bg, label_col)

    base ++ active_draws ++ label_draw ++ icon_draws ++ rail_draws ++ match_draws
  end

  # Returns {prefix_text, indicator_draws, label_col_offset} for the active indicator.
  # `nil` means no item in the list has active set, so no indicator column at all.
  @spec active_indicator(non_neg_integer(), boolean() | nil, map(), non_neg_integer()) ::
          {String.t(), [DisplayList.draw()], non_neg_integer()}
  defp active_indicator(_row, nil, _pc, _bg), do: {"", [], 2}

  defp active_indicator(row, true, pc, bg) do
    active_fg = Map.get(pc, :active_fg, pc.highlight_fg)
    draw = DisplayList.draw(row, 2, "● ", Face.new(fg: active_fg, bg: bg))
    {"● ", [draw], 4}
  end

  defp active_indicator(_row, false, _pc, _bg), do: {"  ", [], 4}

  @spec render_selected_rail(
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp render_selected_rail(_row, _col, false, _fg, _bg), do: []

  defp render_selected_rail(row, col, true, fg, bg) do
    [DisplayList.draw(row, col, "▌", Face.new(fg: fg, bg: bg))]
  end

  # Renders the icon (first grapheme of the label) in its language color.
  # `col_offset` is where the label text starts on the row: 1 for bottom
  # layout (leading space), 0 for centered layout.
  # Renders the icon (first grapheme of the label) in its language color.
  # `col_offset` is where the label starts: 1 for bottom layout (leading
  # space prefix), 0 for centered layout.
  @spec render_icon_color(
          non_neg_integer(),
          non_neg_integer() | nil,
          non_neg_integer(),
          String.t(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp render_icon_color(_row, nil, _bg, _label, _col_offset), do: []

  defp render_icon_color(row, color, bg, label, col_offset) when is_integer(color) do
    case String.next_grapheme(label) do
      {icon, _rest} ->
        [DisplayList.draw(row, col_offset, icon, Face.new(fg: color, bg: bg))]

      nil ->
        []
    end
  end

  @spec centered_item_capacity(pos_integer()) :: pos_integer()
  @spec load_status_message(PickerState.t(), list(), String.t()) :: String.t() | nil
  defp load_status_message(%{load_status: :loading}, _visible, _query), do: "Searching..."
  defp load_status_message(%{load_status: {:error, reason}}, _visible, _query), do: reason
  defp load_status_message(_picker_state, [], query) when query != "", do: "No matches"
  defp load_status_message(_picker_state, _visible, _query), do: nil

  defp centered_item_capacity(viewport_rows) do
    max(div(viewport_rows * 7, 10), 5) - 3
  end

  @spec centered_float_height([Picker.item()], MingaEditor.Viewport.t(), boolean()) ::
          pos_integer()
  defp centered_float_height(visible, viewport, has_status_message) do
    max_height = max(div(viewport.rows * 7, 10), 5)
    item_count = if has_status_message, do: 1, else: length(visible)
    min(item_count + 3, max_height)
  end

  @spec resolve_percent(pos_integer(), pos_integer()) :: pos_integer()
  defp resolve_percent(pct, total), do: max(div(total * pct, 100), 1)

  # ── Mode switching ──────────────────────────────────────────────────────────

  # Check if typing a character should trigger a mode switch.
  # Only triggers on the first character in an empty query, for switchable sources.
  @spec maybe_switch_mode(state(), String.t(), String.t()) ::
          {:switched, state()} | :no_switch
  defp maybe_switch_mode(
         %{shell_state: %{modal: {:picker, %{picker_ui: %{source: source}}}}} = state,
         char,
         query
       ) do
    source_prefixes = Map.get(@mode_prefixes, source, %{})

    if query == "" and Map.has_key?(source_prefixes, char) do
      target_source = Map.fetch!(source_prefixes, char)
      {:switched, switch_to_source(state, target_source, char)}
    else
      :no_switch
    end
  end

  # Switch the picker to a new source module, preserving the original source for switch-back.
  @spec switch_to_source(state(), module(), String.t()) :: state()
  defp switch_to_source(
         %{
           shell_state: %{
             modal: {:picker, %{picker_ui: %{source: current_source, original_source: orig_src}}}
           }
         } = state,
         new_source,
         prefix
       ) do
    ctx = Context.from_editor_state(state)
    items = new_source.candidates(ctx)
    max_vis = max(state.terminal_viewport.rows - 3, 5)
    picker = Picker.new(items, title: new_source.title(), max_visible: max_vis)
    layout = MingaEditor.UI.Picker.Source.layout(new_source)
    original = orig_src || current_source

    update_picker(
      state,
      &%{
        &1
        | picker: picker,
          source: new_source,
          layout: layout,
          original_source: original,
          mode_prefix: prefix
      }
    )
  end

  # Switch back to the original source after the prefix is deleted.
  @spec switch_back_to_original(state()) :: state()
  defp switch_back_to_original(
         %{shell_state: %{modal: {:picker, %{picker_ui: %{original_source: orig}}}}} = state
       ) do
    ctx = Context.from_editor_state(state)
    items = orig.candidates(ctx)
    max_vis = max(state.terminal_viewport.rows - 3, 5)
    picker = Picker.new(items, title: orig.title(), max_visible: max_vis)
    layout = MingaEditor.UI.Picker.Source.layout(orig)

    update_picker(
      state,
      &%{
        &1
        | picker: picker,
          source: orig,
          layout: layout,
          original_source: nil,
          mode_prefix: ""
      }
    )
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Restores the buffer that was active when the picker opened before promoting a preview.
  # Preview leaves the tab bar unchanged, so the outgoing tab must be snapshotted from
  # the original buffer, not the preview buffer currently shown in the window.
  @spec restore_picker_origin(state()) :: state()
  defp restore_picker_origin(
         %{shell_state: %{modal: {:picker, %{picker_ui: %{restore: idx}}}}} = state
       )
       when is_integer(idx) do
    EditorState.switch_buffer(state, idx)
  end

  defp restore_picker_origin(state), do: state

  # Returns true when preview navigation changed the active buffer from
  # what it was when the picker opened (stored in the picker payload's `restore` field).
  @spec previewed?(state()) :: boolean()
  defp previewed?(%{
         shell_state: %{modal: {:picker, %{picker_ui: %{restore: restore}}}},
         workspace: %{buffers: bs}
       })
       when is_integer(restore) do
    bs.active_index != restore
  end

  defp previewed?(_state), do: false

  # Live preview: temporarily apply the source's on_select for the highlighted item.
  # Sets buffer_add_context to :preview so add_buffer calls inside on_select update
  # the current tab in-place instead of creating a new tab.
  @spec maybe_preview_selection(state()) :: state()
  defp maybe_preview_selection(
         %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}} =
           state
       ) do
    if Picker.Source.live_preview?(source) do
      case Picker.selected_item(picker) do
        nil ->
          state

        item ->
          state = EditorState.set_buffer_add_context(state, :preview)
          source.on_select(item, state)
      end
    else
      state
    end
  end

  @type visible_item :: {Picker.item(), pos_integer()}

  @spec bottom_visible_items(Picker.t(), pos_integer()) ::
          {[visible_item()], non_neg_integer(), non_neg_integer()}
  defp bottom_visible_items(%Picker{filtered: []}, _row_budget), do: {[], 0, 0}

  defp bottom_visible_items(%Picker{} = picker, row_budget) do
    {visible, selected_offset} = Picker.visible_items(picker)
    fit_visible_items(visible, selected_offset, row_budget)
  end

  @spec fit_visible_items([Picker.item()], non_neg_integer(), pos_integer()) ::
          {[visible_item()], non_neg_integer(), non_neg_integer()}
  defp fit_visible_items(visible, selected_offset, row_budget) do
    selected_item = Enum.at(visible, selected_offset)
    selected_rows = min(item_row_count(selected_item), row_budget)
    remaining_rows = row_budget - selected_rows
    before_items = Enum.take(visible, selected_offset)
    after_items = Enum.drop(visible, selected_offset + 1)

    {before_entries, before_remaining, before_rows} =
      take_before_visible_items(before_items, div(remaining_rows, 2))

    {after_entries, after_rows} =
      take_after_visible_items(after_items, remaining_rows - before_rows)

    {more_before_entries, _before_remaining, more_before_rows} =
      take_before_visible_items(before_remaining, remaining_rows - before_rows - after_rows)

    visible_entries =
      more_before_entries ++ before_entries ++ [{selected_item, selected_rows}] ++ after_entries

    rows_used = more_before_rows + before_rows + selected_rows + after_rows
    selected_entry_offset = length(more_before_entries) + length(before_entries)

    {visible_entries, selected_entry_offset, rows_used}
  end

  @spec take_before_visible_items([Picker.item()], non_neg_integer()) ::
          {[visible_item()], [Picker.item()], non_neg_integer()}
  defp take_before_visible_items(items, row_budget) do
    {entries_nearest_first, remaining_nearest_first, rows_used} =
      items
      |> Enum.reverse()
      |> take_visible_items_by_rows(row_budget)

    {Enum.reverse(entries_nearest_first), Enum.reverse(remaining_nearest_first), rows_used}
  end

  @spec take_after_visible_items([Picker.item()], non_neg_integer()) ::
          {[visible_item()], non_neg_integer()}
  defp take_after_visible_items(items, row_budget) do
    {entries, _remaining, rows_used} = take_visible_items_by_rows(items, row_budget)
    {entries, rows_used}
  end

  @spec take_visible_items_by_rows([Picker.item()], non_neg_integer()) ::
          {[visible_item()], [Picker.item()], non_neg_integer()}
  defp take_visible_items_by_rows(items, row_budget) do
    take_visible_items_by_rows(items, row_budget, [], 0)
  end

  @spec take_visible_items_by_rows(
          [Picker.item()],
          non_neg_integer(),
          [visible_item()],
          non_neg_integer()
        ) ::
          {[visible_item()], [Picker.item()], non_neg_integer()}
  defp take_visible_items_by_rows([], _row_budget, acc, rows_used) do
    {Enum.reverse(acc), [], rows_used}
  end

  defp take_visible_items_by_rows([item | rest] = remaining, row_budget, acc, rows_used) do
    item_rows = item_row_count(item)

    if rows_used + item_rows <= row_budget do
      take_visible_items_by_rows(
        rest,
        row_budget,
        [{item, item_rows} | acc],
        rows_used + item_rows
      )
    else
      {Enum.reverse(acc), remaining, rows_used}
    end
  end

  @spec row_offset_for_visible_index([visible_item()], non_neg_integer()) :: non_neg_integer()
  defp row_offset_for_visible_index(visible, index) do
    visible
    |> Enum.take(index)
    |> Enum.reduce(0, fn {_item, rows_used}, acc -> acc + rows_used end)
  end

  @spec item_row_count(Picker.item()) :: pos_integer()
  defp item_row_count(%{two_line: true}), do: 2
  defp item_row_count(_item), do: 1

  @spec render_visible_item(
          integer(),
          pos_integer(),
          Picker.item(),
          boolean(),
          String.t(),
          MingaEditor.Viewport.t(),
          map()
        ) :: [DisplayList.draw()]
  defp render_visible_item(row, 1, %{two_line: true} = item, is_selected, query, viewport, colors) do
    render_one_line_item(row, item, is_selected, query, viewport, colors)
  end

  defp render_visible_item(
         row,
         _rows_used,
         %{two_line: true} = item,
         is_selected,
         query,
         viewport,
         colors
       ) do
    render_two_line_item(row, item, is_selected, query, viewport, colors)
  end

  defp render_visible_item(row, _rows_used, item, is_selected, query, viewport, colors) do
    if row < 0 or row >= viewport.rows do
      []
    else
      render_item(
        row,
        item.label,
        item.description,
        is_selected,
        query,
        viewport.cols,
        colors,
        item.icon_color
      )
    end
  end

  @spec render_one_line_item(
          integer(),
          Picker.item(),
          boolean(),
          String.t(),
          MingaEditor.Viewport.t(),
          map()
        ) :: [DisplayList.draw()]
  defp render_one_line_item(row, item, is_selected, query, viewport, colors) do
    if row < 0 or row >= viewport.rows do
      []
    else
      render_item(row, item.label, "", is_selected, query, viewport.cols, colors, item.icon_color)
    end
  end

  @spec render_two_line_item(
          integer(),
          Picker.item(),
          boolean(),
          String.t(),
          MingaEditor.Viewport.t(),
          map()
        ) :: [DisplayList.draw()]
  defp render_two_line_item(row, item, is_selected, query, viewport, colors) do
    row_bg = colors.bg

    label_cmds =
      if row < 0 or row >= viewport.rows do
        []
      else
        render_item(
          row,
          item.label,
          "",
          is_selected,
          query,
          viewport.cols,
          colors,
          item.icon_color
        )
      end

    description_cmds =
      render_two_line_description(row + 1, item.description, row_bg, viewport, colors)

    indicator_cmds =
      render_two_line_selection_indicator(row, is_selected, row_bg, viewport, colors)

    label_cmds ++ description_cmds ++ indicator_cmds
  end

  @spec render_two_line_description(
          integer(),
          String.t(),
          non_neg_integer(),
          MingaEditor.Viewport.t(),
          map()
        ) ::
          [DisplayList.draw()]
  defp render_two_line_description(row, description, row_bg, viewport, colors) do
    if row < 0 or row >= viewport.rows do
      []
    else
      text =
        ("  " <> description)
        |> Unicode.truncate_display_width(viewport.cols)
        |> Unicode.pad_display_trailing(viewport.cols)

      [DisplayList.draw(row, 0, text, Face.new(fg: colors.dim_fg, bg: row_bg))]
    end
  end

  @spec render_two_line_selection_indicator(
          integer(),
          boolean(),
          non_neg_integer(),
          MingaEditor.Viewport.t(),
          map()
        ) ::
          [DisplayList.draw()]
  defp render_two_line_selection_indicator(_row, false, _row_bg, _viewport, _colors), do: []

  defp render_two_line_selection_indicator(row, true, row_bg, viewport, colors) do
    [row, row + 1]
    |> Enum.filter(&(&1 >= 0 and &1 < viewport.rows))
    |> Enum.map(fn indicator_row ->
      DisplayList.draw(indicator_row, 0, "▌", Face.new(fg: colors.highlight_fg, bg: row_bg))
    end)
  end

  # Renders a single picker item row with background, match highlights, and description.
  @spec render_item(
          non_neg_integer(),
          String.t(),
          String.t(),
          boolean(),
          String.t(),
          pos_integer(),
          map(),
          non_neg_integer() | nil
        ) :: [DisplayList.draw()]
  defp render_item(row, label, desc, is_selected, query, cols, colors, icon_color) do
    fg = if is_selected, do: colors.highlight_fg, else: colors.text_fg
    row_bg = colors.bg

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
      DisplayList.draw(
        row,
        0,
        String.pad_trailing(row_text, cols),
        Face.new(fg: fg, bg: row_bg, bold: is_selected)
      )

    highlight_cmds = render_match_highlights(row, label, query, colors.match_fg, row_bg)

    icon_cmds = render_icon_color(row, icon_color, row_bg, label, 1)
    rail_cmds = render_selected_rail(row, 0, is_selected, colors.highlight_fg, row_bg)

    desc_cmds =
      if desc_display != "" do
        desc_start = cols - Unicode.display_width(desc_display) - 1
        [DisplayList.draw(row, desc_start, desc_display, Face.new(fg: colors.dim_fg, bg: row_bg))]
      else
        []
      end

    [bg_cmd | icon_cmds] ++ rail_cmds ++ highlight_cmds ++ desc_cmds
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
    render_match_highlights_at(row, label, query, match_fg, row_bg, 1)
  end

  # Like `render_match_highlights/5` but with a configurable column offset
  # for the label start position.
  @spec render_match_highlights_at(
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp render_match_highlights_at(row, label, query, match_fg, row_bg, col_offset) do
    match_positions = Picker.match_positions(label, query)

    label_graphemes = String.graphemes(label)
    label_len = Enum.count(label_graphemes)

    match_positions
    |> Enum.filter(&(&1 < label_len))
    |> Enum.map(fn pos ->
      char = Enum.at(label_graphemes, pos)
      col = col_offset + display_width_before(label_graphemes, pos)
      DisplayList.draw(row, col, char, Face.new(fg: match_fg, bg: row_bg, bold: true))
    end)
  end

  @spec display_width_before([String.t()], non_neg_integer()) :: non_neg_integer()
  defp display_width_before(graphemes, pos) do
    graphemes
    |> Enum.take(pos)
    |> Enum.reduce(0, fn grapheme, width -> width + Unicode.display_width(grapheme) end)
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
          DisplayList.draw(
            header_row,
            menu_col,
            header_text,
            Face.new(fg: border_fg, bg: menu_bg, bold: true)
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

    [DisplayList.draw(row, col, text, Face.new(fg: fg, bg: bg, bold: is_sel))]
  end
end
