defmodule MingaEditor.Input.Router do
  @moduledoc """
  Walks the focus stack to dispatch a key press, then runs centralized
  post-action housekeeping.

  The focus stack is an ordered list of `MingaEditor.Input.Handler` modules.
  `dispatch/3` calls each handler's `handle_key/3` in order via
  `Enum.reduce_while/3`. The first handler that returns `{:handled, state}`
  stops the walk. If all handlers pass through, the key is silently dropped.

  After dispatch, `post_key_housekeeping/6` runs keyboard-specific steps
  (completion triggering) then delegates to `post_action_housekeeping/2`
  for the universal pipeline shared by all input paths (keyboard, mouse,
  GUI actions).
  """

  alias Minga.Buffer
  alias Minga.Editing
  alias MingaEditor
  alias MingaEditor.FocusTree
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.KeystrokeHistory
  alias MingaEditor.LspActions
  alias MingaEditor.State, as: EditorState

  @typedoc "Pre-action snapshot for housekeeping comparisons."
  @type snapshot :: %{
          old_buffer: pid() | nil,
          buf_version: non_neg_integer(),
          old_mode: atom(),
          old_cursor: {non_neg_integer(), non_neg_integer()} | nil
        }

  @typep mouse_event :: %{
           row: integer(),
           col: integer(),
           button: atom(),
           mods: non_neg_integer(),
           event_type: atom(),
           click_count: pos_integer()
         }

  @doc """
  Captures a snapshot of the editor state before an action runs.

  Call this before dispatching any action (key press, mouse event, GUI action)
  and pass the result to `post_action_housekeeping/2` afterward.
  """
  @spec capture_snapshot(EditorState.t()) :: snapshot()
  def capture_snapshot(state) do
    %{
      old_buffer: state.workspace.buffers.active,
      buf_version: buffer_version(state),
      old_mode: Editing.mode(state),
      old_cursor: safe_cursor(state.workspace.buffers.active)
    }
  end

  @doc """
  Dispatches a key press through the focus stack and runs post-key housekeeping.

  Captures the buffer version, active buffer, and mode before dispatch so
  housekeeping can detect what changed.
  """
  @spec dispatch(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  def dispatch(state, codepoint, modifiers) do
    # Intercept keys when a quit confirmation prompt is active.
    # y/n/Escape are handled here; all other keys are ignored.
    if state.pending_quit do
      return_dispatch_confirm_quit(state, codepoint)
    else
      dispatch_normal(state, codepoint, modifiers)
    end
  end

  @spec return_dispatch_confirm_quit(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp return_dispatch_confirm_quit(state, codepoint) do
    alias MingaEditor.Commands

    case codepoint do
      ?y ->
        Commands.execute(state, :confirm_quit_yes)

      cancel when cancel in [?n, 27] ->
        new_state = Commands.execute(state, :confirm_quit_no)
        # Run housekeeping so the cleared prompt triggers a render.
        post_key_housekeeping(
          new_state,
          state.workspace.buffers.active,
          buffer_version(state),
          Editing.mode(state),
          Editing.inserting?(state),
          {cancel, 0}
        )

      _ ->
        state
    end
  end

  @spec dispatch_normal(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp dispatch_normal(state, codepoint, modifiers) do
    old_buffer = state.workspace.buffers.active
    old_mode = Editing.mode(state)
    was_inserting = Editing.inserting?(state)
    buf_version_before = buffer_version(state)
    old_cursor = safe_cursor(old_buffer)

    state = EditorState.clear_status(state)

    state = dispatch_split(state, codepoint, modifiers)
    state = record_keystroke(state, codepoint, modifiers, old_mode)

    post_key_housekeeping(
      state,
      old_buffer,
      buf_version_before,
      old_mode,
      was_inserting,
      {codepoint, modifiers},
      old_cursor
    )
  end

  # Walks overlay handlers first (ConflictPrompt, Picker, Completion).
  # If none consume the key, delegates to surface handlers (Scoped, GlobalBindings, ModeFSM).
  @spec dispatch_split(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp dispatch_split(%EditorState{shell: shell, shell_state: _ss} = state, codepoint, modifiers) do
    %{overlay: overlay_handlers, surface: _surface} = shell.input_handlers(state)

    case walk_handlers_until_passthrough(overlay_handlers, state, codepoint, modifiers) do
      {:handled, new_state} ->
        new_state

      {:passthrough, state_after_overlays} ->
        dispatch_to_surface(state_after_overlays, codepoint, modifiers)
    end
  end

  # Delegates a key press to surface handlers.
  #
  # Editor handlers (Scoped, GlobalBindings, ModeFSM) operate on EditorState
  # directly. This preserves all side effects (status_msg, focus_stack changes,
  # mode transitions) that handlers produce.
  @spec dispatch_to_surface(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp dispatch_to_surface(
         %EditorState{shell: shell, shell_state: _ss} = state,
         codepoint,
         modifiers
       ) do
    %{surface: surface_handlers} = shell.input_handlers(state)

    Enum.reduce_while(surface_handlers, state, fn handler, acc ->
      case handler.handle_key(acc, codepoint, modifiers) do
        {:handled, new_state} -> {:halt, new_state}
        {:passthrough, new_state} -> {:cont, new_state}
      end
    end)
  end

  @doc """
  Universal post-action housekeeping shared by all input paths (keyboard,
  mouse, GUI actions).

  Runs highlight reset, reparse, selection range cleanup, document highlight
  scheduling, inlay hint scheduling, and render. Call after any action that
  mutates editor state.
  """
  @spec post_action_housekeeping(EditorState.t(), snapshot()) :: EditorState.t()
  def post_action_housekeeping(state, snapshot) do
    state
    |> MingaEditor.do_maybe_reset_highlight(snapshot.old_buffer)
    |> MingaEditor.do_maybe_reparse(snapshot.buf_version)
    |> maybe_clear_selection_ranges(snapshot.old_mode)
    |> maybe_schedule_document_highlight(snapshot.old_buffer, snapshot.old_cursor)
    |> LspActions.schedule_inlay_hints_on_scroll()
    |> maybe_render(snapshot.buf_version)
  end

  @doc """
  Keyboard-specific post-key housekeeping. Handles completion triggering
  (which needs the codepoint/modifiers), then delegates to
  `post_action_housekeeping/2` for the universal pipeline.
  """
  @spec post_key_housekeeping(
          EditorState.t(),
          pid() | nil,
          non_neg_integer(),
          atom(),
          boolean(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()} | nil
        ) :: EditorState.t()
  def post_key_housekeeping(
        state,
        old_buffer,
        buf_version_before,
        old_mode,
        was_inserting,
        {codepoint, modifiers},
        old_cursor \\ nil
      ) do
    snapshot = %{
      old_buffer: old_buffer,
      buf_version: buf_version_before,
      old_mode: old_mode,
      old_cursor: old_cursor
    }

    state
    |> MingaEditor.do_maybe_handle_completion(was_inserting, codepoint, modifiers)
    |> post_action_housekeeping(snapshot)
  end

  # Clears selection range state when leaving visual mode by any means.
  # This ensures the stored selection range chain doesn't linger after
  # the user exits visual mode (Escape, entering normal mode, switching buffers).
  @spec maybe_clear_selection_ranges(EditorState.t(), atom()) :: EditorState.t()
  defp maybe_clear_selection_ranges(
         %EditorState{lsp: %{selection_ranges: ranges}} = state,
         old_mode
       )
       when old_mode == :visual and ranges != nil do
    if Editing.mode(state) != :visual do
      EditorState.update_lsp(state, &MingaEditor.State.LSP.clear_selection_ranges/1)
    else
      state
    end
  end

  defp maybe_clear_selection_ranges(state, _old_mode), do: state

  # Schedules a debounced document highlight request when the cursor moves
  # in normal mode. Clears highlights on buffer switch or mode change.
  # Only schedules when the cursor actually moved (avoids timer churn on
  # keystrokes that don't change position, like failed motions or `zz`).
  @spec maybe_schedule_document_highlight(
          EditorState.t(),
          pid() | nil,
          {non_neg_integer(), non_neg_integer()} | nil
        ) :: EditorState.t()
  defp maybe_schedule_document_highlight(state, old_buffer, old_cursor)

  # Buffer changed: clear highlights
  defp maybe_schedule_document_highlight(
         %EditorState{workspace: %{buffers: %{active: current}}} = state,
         old_buffer,
         _old_cursor
       )
       when current != old_buffer do
    LspActions.clear_document_highlights(state)
  end

  # Normal mode, no buffer: no-op
  defp maybe_schedule_document_highlight(
         %EditorState{workspace: %{buffers: %{active: nil}}} = state,
         _old_buffer,
         _old_cursor
       ) do
    state
  end

  # Same buffer: check mode and cursor
  defp maybe_schedule_document_highlight(state, _old_buffer, old_cursor) do
    if Editing.mode(state) != :normal do
      # Not normal mode: clear highlights
      LspActions.clear_document_highlights(state)
    else
      # Normal mode with a live buffer: schedule only if cursor moved
      new_cursor = safe_cursor(state.workspace.buffers.active)

      if new_cursor != old_cursor do
        state = LspActions.schedule_document_highlight(state)
        LspActions.schedule_inlay_hints_on_scroll(state)
      else
        state
      end
    end
  end

  @spec safe_cursor(pid() | nil) :: {non_neg_integer(), non_neg_integer()} | nil
  defp safe_cursor(nil), do: nil

  defp safe_cursor(buf) do
    Buffer.cursor(buf)
  catch
    :exit, _ -> nil
  end

  # Skips the full render when entering operator-pending mode with no buffer
  # change. This prevents the visible flicker between keystrokes of compound
  # operators like `dd`, `cc`, `yy`, etc. The first keystroke is a zero-cost
  # state flag, not a mode change that warrants a screen redraw.
  #
  # A bare `batch_end` is still emitted so that frame-synchronization contracts
  # (HeadlessPort in tests, future frame-pacing in production) remain satisfied.
  @spec maybe_render(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp maybe_render(state, buf_version_before) do
    if Editing.mode(state) == :operator_pending and
         buffer_version(state) == buf_version_before do
      MingaEditor.Frontend.send_batch_end(state.port_manager)
      state
    else
      MingaEditor.do_render(state)
    end
  end

  @doc """
  Dispatches a mouse event through the focus tree.

  Hit-testing resolves `(row, col)` to the deepest visible node. Dispatch starts at that node's handler and bubbles to ancestors when a handler returns `{:passthrough, state}`. Scroll-wheel events start at the deepest scrollable node under the cursor, so hover location controls scrolling independently of keyboard focus.
  """
  @spec dispatch_mouse(
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: EditorState.t()
  def dispatch_mouse(
        %{workspace: %{mouse: %{dragging: true}}} = state,
        row,
        col,
        :left,
        mods,
        event_type,
        click_count
      )
      when event_type in [:drag, :release] do
    MingaEditor.Mouse.handle(state, row, col, :left, mods, event_type, click_count)
  end

  def dispatch_mouse(state, row, col, _button, _mods, _event_type, _click_count)
      when row < 0 or col < 0 do
    state
  end

  def dispatch_mouse(state, row, col, button, mods, event_type, click_count) do
    event = %{
      row: row,
      col: col,
      button: button,
      mods: mods,
      event_type: event_type,
      click_count: click_count
    }

    state
    |> FocusTree.get()
    |> mouse_path(row, col, button)
    |> dispatch_mouse_path(state, event)
  end

  @spec mouse_path(FocusTree.t(), integer(), integer(), atom()) :: FocusTree.path()
  defp mouse_path(tree, row, col, button)
       when button in [:wheel_down, :wheel_up, :wheel_left, :wheel_right] do
    case FocusTree.scroll_path(tree, row, col) do
      [] -> FocusTree.hit_path(tree, row, col)
      path -> path
    end
  end

  defp mouse_path(tree, row, col, _button), do: FocusTree.hit_path(tree, row, col)

  @spec dispatch_mouse_path(FocusTree.path(), EditorState.t(), mouse_event()) :: EditorState.t()
  defp dispatch_mouse_path(path, state, event) do
    Enum.reduce_while(path, state, fn node, acc ->
      case dispatch_mouse_to_node(node, acc, event) do
        {:handled, new_state} -> {:halt, new_state}
        {:passthrough, new_state} -> {:cont, new_state}
      end
    end)
  end

  @spec dispatch_mouse_to_node(FocusNode.t(), EditorState.t(), mouse_event()) ::
          MingaEditor.Input.Handler.result()
  defp dispatch_mouse_to_node(%FocusNode{handler: nil}, state, _event) do
    {:passthrough, state}
  end

  defp dispatch_mouse_to_node(%FocusNode{handler: handler} = node, state, event) do
    Code.ensure_loaded(handler)
    call_mouse_handler(handler, node, state, event)
  end

  @spec call_mouse_handler(module(), FocusNode.t(), EditorState.t(), mouse_event()) ::
          MingaEditor.Input.Handler.result()
  defp call_mouse_handler(handler, node, state, event) do
    if function_exported?(handler, :handle_mouse_at_node, 8) do
      handler.handle_mouse_at_node(
        state,
        node,
        event.row,
        event.col,
        event.button,
        event.mods,
        event.event_type,
        event.click_count
      )
    else
      call_legacy_mouse_handler(handler, state, event)
    end
  end

  @spec call_legacy_mouse_handler(module(), EditorState.t(), mouse_event()) ::
          MingaEditor.Input.Handler.result()
  defp call_legacy_mouse_handler(handler, state, event) do
    if function_exported?(handler, :handle_mouse, 7) do
      handler.handle_mouse(
        state,
        event.row,
        event.col,
        event.button,
        event.mods,
        event.event_type,
        event.click_count
      )
    else
      {:passthrough, state}
    end
  end

  # Walks handlers and reports whether any consumed the key.
  # Returns {:handled, state} if a handler consumed it, or
  # {:passthrough, state} if all handlers passed through.
  @spec walk_handlers_until_passthrough(
          [module()],
          EditorState.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  defp walk_handlers_until_passthrough(handlers, state, codepoint, modifiers) do
    Enum.reduce_while(handlers, {:passthrough, state}, fn handler, {_status, acc} ->
      case handler.handle_key(acc, codepoint, modifiers) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

  @spec record_keystroke(EditorState.t(), non_neg_integer(), non_neg_integer(), atom()) ::
          EditorState.t()
  defp record_keystroke(state, codepoint, modifiers, mode_before) do
    entry = %KeystrokeHistory.Entry{
      key: {codepoint, modifiers},
      mode_before: mode_before,
      mode_after: Editing.mode(state),
      timestamp: :os.system_time(:millisecond)
    }

    %{state | keystroke_history: KeystrokeHistory.record(state.keystroke_history, entry)}
  end

  @spec buffer_version(EditorState.t()) :: non_neg_integer()
  defp buffer_version(%{workspace: %{buffers: %{active: nil}}}), do: 0

  defp buffer_version(%{workspace: %{buffers: %{active: buf}}}) do
    Buffer.version(buf)
  end
end
