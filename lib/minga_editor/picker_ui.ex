defmodule MingaEditor.PickerUI do
  @moduledoc """
  Picker orchestration and modal state: open, key handling, close, and refresh.

  This is the live picker state layer used by the command palette, file finder,
  buffer list, LSP actions, and agent pickers. All functions are pure
  `state → state` or `state → {state, action}` transformations; the GenServer
  dispatches any returned action tuple.

  The modal `picker_ui` state these functions produce is read directly by the
  semantic render-model builder (`RenderModel.UI.PickerBuilder`), which emits the
  `gui_picker` command consumed by the GUI and Go TUI frontends. This module no
  longer renders the picker itself; the cell-grid renderer that previously lived
  here was deleted with the rest of the cell paradigm.

  ## Action tuples

  `handle_key/3` may return `{state, {:execute_command, cmd}}` when the user
  confirms a selection that triggers a command (e.g. command palette → `:save`).
  The caller (`Editor`) is responsible for dispatching that action.
  """

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.BufferLifecycle
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
    {new_state, revision} = open_loading(state, source_module, context)

    send(
      self(),
      {:picker_fetch_candidates, source_module, revision,
       Context.from_editor_state(state, context)}
    )

    new_state
  end

  @doc "Opens an async picker in its loading state without starting a fetch."
  @spec open_loading(state(), module(), map() | nil) :: {state(), reference()}
  def open_loading(state, source_module, context \\ nil) do
    max_vis = max(state.frontend.terminal_viewport.rows - 3, 5)
    picker = Picker.new([], title: source_module.title(), max_visible: max_vis)

    new_state = clear_whichkey(state)
    layout = MingaEditor.UI.Picker.Source.layout(source_module)

    picker_state = %PickerState{
      picker: picker,
      source: source_module,
      restore: state.workspace.buffers.active_index,
      restore_theme: state.appearance.theme,
      context: context,
      layout: layout,
      load_status: :loading
    }

    {picker_state, revision} = PickerState.begin_fetch(picker_state)

    new_state =
      MingaEditor.Shell.Traditional.ModalWorkflow.open(
        new_state,
        {:picker, PickerPayload.new(picker_state)}
      )

    {new_state, revision}
  end

  @doc "Applies a scheduler-owned candidate result when its picker revision is live."
  @spec apply_fetch_result(state(), module(), reference(), tuple()) ::
          {:ok, state()} | :stale
  def apply_fetch_result(state, source_module, revision, {:ok, items, candidates, meta}) do
    case live_picker(state, source_module, revision) do
      {:ok, payload} ->
        picker_state = payload.picker_ui
        picker = Picker.put_candidates(picker_state.picker, items, candidates)
        new_picker_state = %{picker_state | picker: picker, load_status: :ready}

        new_state =
          state
          |> MingaEditor.Shell.Traditional.ModalWorkflow.transition(
            {:picker, PickerPayload.put_picker_ui(payload, new_picker_state)}
          )
          |> apply_fetch_status(meta)

        {:ok, new_state}

      :stale ->
        :stale
    end
  end

  def apply_fetch_result(state, source_module, revision, {:error, reason}) do
    case live_picker(state, source_module, revision) do
      {:ok, payload} ->
        picker_state = payload.picker_ui
        new_picker_state = %{picker_state | load_status: {:error, reason}}

        {:ok,
         MingaEditor.Shell.Traditional.ModalWorkflow.transition(
           state,
           {:picker, PickerPayload.put_picker_ui(payload, new_picker_state)}
         )}

      :stale ->
        :stale
    end
  end

  defp live_picker(state, source_module, revision) do
    case state.shell_runtime.state.modal do
      {:picker, %PickerPayload{picker_ui: %{source: ^source_module} = picker_ui} = payload} ->
        if PickerState.current_fetch?(picker_ui, revision), do: {:ok, payload}, else: :stale

      _ ->
        :stale
    end
  end

  defp apply_fetch_status(state, %{status: status}) when is_binary(status) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, status)
  end

  defp apply_fetch_status(state, _meta), do: state

  @spec open_with_items(state(), module(), [Picker.item()], map() | nil) :: state()
  defp open_with_items(state, source_module, items, context) do
    max_vis = max(state.frontend.terminal_viewport.rows - 3, 5)
    picker = Picker.new(items, title: source_module.title(), max_visible: max_vis)

    new_state = clear_whichkey(state)
    layout = MingaEditor.UI.Picker.Source.layout(source_module)

    picker_state = %PickerState{
      picker: picker,
      source: source_module,
      restore: state.workspace.buffers.active_index,
      restore_theme: state.appearance.theme,
      context: context,
      layout: layout
    }

    MingaEditor.Shell.Traditional.ModalWorkflow.open(
      new_state,
      {:picker, PickerPayload.new(picker_state)}
    )
  end

  @spec clear_whichkey(state()) :: state()
  defp clear_whichkey(state),
    do: MingaEditor.Shell.Traditional.WhichKeyWorkflow.dismiss(state)

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
        %{
          shell_runtime: %{
            state: %{modal: {:picker, %{picker_ui: %{action_menu: {_actions, _sel}}}}}
          }
        } =
          state,
        @escape,
        _mods
      ) do
    update_picker(state, &%{&1 | action_menu: nil})
  end

  def handle_key(
        %{
          shell_runtime: %{
            state: %{modal: {:picker, %{picker_ui: %{action_menu: {_actions, _sel}}}}}
          }
        } =
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
          shell_runtime: %{
            state: %{
              modal:
                {:picker,
                 %{picker_ui: %{action_menu: {actions, sel}, picker: picker, source: source}}}
            }
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
        %{
          shell_runtime: %{
            state: %{modal: {:picker, %{picker_ui: %{action_menu: {actions, sel}}}}}
          }
        } = state,
        cp,
        mods
      )
      when (cp == ?j and band(mods, @ctrl) != 0) or
             (cp == ?n and band(mods, @ctrl) != 0) or
             cp == @arrow_down do
    new_sel = rem(sel + 1, Enum.count(actions))
    update_picker(state, &%{&1 | action_menu: {actions, new_sel}})
  end

  # Arrow up / C-k / C-p in action menu → move selection up
  def handle_key(
        %{
          shell_runtime: %{
            state: %{modal: {:picker, %{picker_ui: %{action_menu: {actions, sel}}}}}
          }
        } = state,
        cp,
        mods
      )
      when (cp == ?k and band(mods, @ctrl) != 0) or
             (cp == ?p and band(mods, @ctrl) != 0) or
             cp == @arrow_up do
    new_sel = if sel == 0, do: Enum.count(actions) - 1, else: sel - 1
    update_picker(state, &%{&1 | action_menu: {actions, new_sel}})
  end

  # Ignore all other keys while action menu is open
  def handle_key(
        %{
          shell_runtime: %{
            state: %{modal: {:picker, %{picker_ui: %{action_menu: {_actions, _sel}}}}}
          }
        } =
          state,
        _cp,
        _mods
      ),
      do: state

  # ── Normal picker handlers ─────────────────────────────────────────────────

  def handle_key(
        %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{source: source}}}}}} = state,
        @escape,
        _mods
      ) do
    new_state = source.on_cancel(state)
    close(new_state)
  end

  # C-g → cancel (Emacs-style)
  def handle_key(
        %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{source: source}}}}}} = state,
        ?g,
        mods
      )
      when band(mods, @ctrl) != 0 do
    new_state = source.on_cancel(state)
    close(new_state)
  end

  def handle_key(
        %{
          shell_runtime: %{
            state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}
          }
        } =
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
        %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}}} = state,
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
        %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}}} = state,
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
        %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}}} = state,
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
        %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}}} = state,
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
        %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}}} = state,
        9,
        _mods
      ) do
    new_picker = picker |> Picker.toggle_mark() |> Picker.move_down()
    update_picker(state, &%{&1 | picker: new_picker})
  end

  # C-o → open action menu for the selected item
  def handle_key(
        %{
          shell_runtime: %{
            state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}
          }
        } =
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
        %{
          shell_runtime: %{
            state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}
          }
        } =
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
          shell_runtime: %{
            state: %{
              modal:
                {:picker,
                 %{picker_ui: %{picker: picker, mode_prefix: prefix, original_source: orig}}}
            }
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
        %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}}} = state,
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
      |> MingaEditor.Handlers.BufferRegistry.add_buffer(previewed_pid, context: :open)

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

  @doc "Closes the picker and resets picker-related state."
  @spec close(state()) :: state()
  def close(state) do
    state
    |> then(fn state ->
      %{state | buffer_lifecycle: BufferLifecycle.expect_buffer(state.buffer_lifecycle, :open)}
    end)
    |> MingaEditor.Shell.Traditional.ModalWorkflow.dismiss()
  end

  @doc """
  Refreshes the picker items from the source while preserving the query
  and selection position. Used by keep-open pickers (e.g., tool manager)
  to update item status after an action.
  """
  @spec refresh_items(state()) :: state()
  def refresh_items(
        %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{picker: nil}}}}}} = state
      ),
      do: state

  def refresh_items(
        %{
          shell_runtime: %{
            state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}
          }
        } =
          state
      ) do
    ctx = Context.from_editor_state(state)
    items = source.candidates(ctx)
    refreshed = %{picker | items: items}
    refreshed = Picker.filter(refreshed, picker.query)

    # Clamp selection to new item count
    max_sel = max(Enum.count(refreshed.filtered) - 1, 0)
    refreshed = %{refreshed | selected: min(picker.selected, max_sel)}

    update_picker(state, &%{&1 | picker: refreshed})
  end

  @doc """
  Applies `fun` to the current PickerState inside the modal and writes back
  via MingaEditor.Shell.Traditional.ModalWorkflow.transition, keeping the modal sum type and consistency
  check in sync.

  Public so that `Input.Picker` (mouse handler) can update scroll position
  without going through the full key-handling path.
  """
  @spec update_picker(state(), (PickerState.t() -> PickerState.t())) :: state()
  def update_picker(state, fun) do
    {:picker, payload} = state.shell_runtime.state.modal
    new_pui = fun.(payload.picker_ui)

    MingaEditor.Shell.Traditional.ModalWorkflow.transition(
      state,
      {:picker, PickerPayload.put_picker_ui(payload, new_pui)}
    )
  end

  # ── Mode switching ──────────────────────────────────────────────────────────

  # Check if typing a character should trigger a mode switch.
  # Only triggers on the first character in an empty query, for switchable sources.
  @spec maybe_switch_mode(state(), String.t(), String.t()) ::
          {:switched, state()} | :no_switch
  defp maybe_switch_mode(
         %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{source: source}}}}}} = state,
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
           shell_runtime: %{
             state: %{
               modal:
                 {:picker, %{picker_ui: %{source: current_source, original_source: orig_src}}}
             }
           }
         } = state,
         new_source,
         prefix
       ) do
    ctx = Context.from_editor_state(state)
    items = new_source.candidates(ctx)
    max_vis = max(state.frontend.terminal_viewport.rows - 3, 5)
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
         %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{original_source: orig}}}}}} =
           state
       ) do
    ctx = Context.from_editor_state(state)
    items = orig.candidates(ctx)
    max_vis = max(state.frontend.terminal_viewport.rows - 3, 5)
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
         %{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{restore: idx}}}}}} = state
       )
       when is_integer(idx) do
    MingaEditor.BufferActivation.activate(state, idx)
  end

  defp restore_picker_origin(state), do: state

  # Returns true when preview navigation changed the active buffer from
  # what it was when the picker opened (stored in the picker payload's `restore` field).
  @spec previewed?(state()) :: boolean()
  defp previewed?(%{
         shell_runtime: %{state: %{modal: {:picker, %{picker_ui: %{restore: restore}}}}},
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
         %{
           shell_runtime: %{
             state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}
           }
         } =
           state
       ) do
    if Picker.Source.live_preview?(source) do
      case Picker.selected_item(picker) do
        nil ->
          state

        item ->
          state = %{
            state
            | buffer_lifecycle: BufferLifecycle.expect_buffer(state.buffer_lifecycle, :preview)
          }

          source.on_select(item, state)
      end
    else
      state
    end
  end
end
