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
    old_mode = state.mode
    buf_version_before = buffer_version(state)

    state = %{state | status_msg: nil}

    state =
      Enum.reduce_while(state.focus_stack, state, fn handler, acc ->
        case handler.handle_key(acc, codepoint, modifiers) do
          {:handled, new_state} -> {:halt, new_state}
          {:passthrough, new_state} -> {:cont, new_state}
        end
      end)

    post_key_housekeeping(state, old_buffer, buf_version_before, old_mode, {codepoint, modifiers})
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

  @spec buffer_version(EditorState.t()) :: non_neg_integer()
  defp buffer_version(%{buffers: %{active: nil}}), do: 0

  defp buffer_version(%{buffers: %{active: buf}}) do
    BufferServer.version(buf)
  end
end
