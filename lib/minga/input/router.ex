defmodule Minga.Input.Router do
  @moduledoc """
  Walks the focus stack to dispatch a key press, then runs centralized
  post-key housekeeping.

  The focus stack is an ordered list of `Minga.Input.Handler` modules.
  `dispatch/3` calls each handler's `handle_key/3` in order via
  `Enum.reduce_while/3`. The first handler that returns `{:handled, state}`
  stops the walk. If all handlers pass through, the key is silently dropped.

  After dispatch, `post_key_housekeeping/5` runs highlight sync, reparse,
  completion handling, and render exactly once regardless of which handler
  consumed the key.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor
  alias Minga.Editor.State, as: EditorState

  @doc """
  Dispatches a key press through the focus stack and runs post-key housekeeping.

  Captures the buffer version, active buffer, and mode before dispatch so
  housekeeping can detect what changed.
  """
  @spec dispatch(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  def dispatch(state, codepoint, modifiers) do
    old_buffer = state.buffers.active
    old_mode = state.vim.mode
    buf_version_before = buffer_version(state)

    state = %{state | status_msg: nil}

    state = dispatch_split(state, codepoint, modifiers)

    post_key_housekeeping(state, old_buffer, buf_version_before, old_mode, {codepoint, modifiers})
  end

  # Walks overlay handlers first (ConflictPrompt, Picker, Completion).
  # If none consume the key, delegates to surface handlers (Scoped, GlobalBindings, ModeFSM).
  @spec dispatch_split(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp dispatch_split(%EditorState{} = state, codepoint, modifiers) do
    overlay_handlers = Minga.Input.overlay_handlers()

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
  defp dispatch_to_surface(state, codepoint, modifiers) do
    Enum.reduce_while(Minga.Input.surface_handlers(), state, fn handler, acc ->
      case handler.handle_key(acc, codepoint, modifiers) do
        {:handled, new_state} -> {:halt, new_state}
        {:passthrough, new_state} -> {:cont, new_state}
      end
    end)
  end

  @doc """
  Runs post-key housekeeping: highlight sync, reparse, completion handling,
  and render. Called exactly once per key press after dispatch.
  """
  @spec post_key_housekeeping(
          EditorState.t(),
          pid() | nil,
          non_neg_integer(),
          atom(),
          {non_neg_integer(), non_neg_integer()}
        ) :: EditorState.t()
  def post_key_housekeeping(
        state,
        old_buffer,
        buf_version_before,
        old_mode,
        {codepoint, modifiers}
      ) do
    state
    |> Editor.do_maybe_reset_highlight(old_buffer)
    |> Editor.do_maybe_reparse(buf_version_before)
    |> Editor.do_maybe_handle_completion(old_mode, codepoint, modifiers)
    |> Editor.do_render()
  end

  @doc """
  Dispatches a mouse event through the focus stack.

  Walks the focus stack calling `handle_mouse/7` on each handler that
  implements it. The first handler that returns `{:handled, state}` stops
  the walk. Handlers that don't implement `handle_mouse/7` are skipped.

  Returns the final state after dispatch.
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
  def dispatch_mouse(state, row, col, button, mods, event_type, click_count) do
    dispatch_mouse_split(state, row, col, button, mods, event_type, click_count)
  end

  # Walks overlay handlers first for mouse events, then delegates to surface handlers.
  @spec dispatch_mouse_split(
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) ::
          EditorState.t()
  defp dispatch_mouse_split(%EditorState{} = state, row, col, button, mods, et, cc) do
    overlay_handlers = Minga.Input.overlay_handlers()

    # Walk overlay handlers first for mouse events.
    result =
      Enum.reduce_while(overlay_handlers, {:passthrough, state}, fn handler, {_status, acc} ->
        case try_mouse_handler(handler, acc, row, col, button, mods, et, cc) do
          {:halt, new_state} -> {:halt, {:handled, new_state}}
          {:cont, new_state} -> {:cont, {:passthrough, new_state}}
        end
      end)

    case result do
      {:handled, new_state} ->
        new_state

      {:passthrough, state_after_overlays} ->
        # Delegate to surface-level mouse handlers.
        Enum.reduce_while(Minga.Input.surface_handlers(), state_after_overlays, fn handler, acc ->
          try_mouse_handler(handler, acc, row, col, button, mods, et, cc)
        end)
    end
  end

  @spec try_mouse_handler(
          module(),
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) ::
          {:halt, EditorState.t()} | {:cont, EditorState.t()}
  defp try_mouse_handler(handler, state, row, col, button, mods, event_type, click_count) do
    Code.ensure_loaded(handler)

    if function_exported?(handler, :handle_mouse, 7) do
      case handler.handle_mouse(state, row, col, button, mods, event_type, click_count) do
        {:handled, new_state} -> {:halt, new_state}
        {:passthrough, new_state} -> {:cont, new_state}
      end
    else
      {:cont, state}
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

  @spec buffer_version(EditorState.t()) :: non_neg_integer()
  defp buffer_version(%{buffers: %{active: nil}}), do: 0

  defp buffer_version(%{buffers: %{active: buf}}) do
    BufferServer.version(buf)
  end
end
