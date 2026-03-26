defmodule Minga.Input.ConflictPrompt do
  @moduledoc """
  Input handler for the file-changed-on-disk conflict prompt.

  When a buffer's file has been modified externally and the user hasn't
  responded yet, this handler intercepts all keys. `r` reloads the buffer
  from disk, `k` keeps the local version, and all other keys are swallowed.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Buffer
  alias Minga.Editor.State, as: EditorState

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{workspace: %{pending_conflict: {buf, _path}}} = state, ?r, _mods)
      when is_pid(buf) do
    Buffer.reload(buf)
    name = Path.basename(Buffer.file_path(buf) || "buffer")

    {:handled,
     %{state | workspace: %{state.workspace | pending_conflict: nil}}
     |> EditorState.set_status("#{name} reloaded (changed on disk)")}
  end

  def handle_key(%{workspace: %{pending_conflict: {buf, _path}}} = state, ?k, _mods)
      when is_pid(buf) do
    buf_state = :sys.get_state(buf)

    case File.stat(buf_state.file_path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} ->
        :sys.replace_state(buf, fn s -> %{s | mtime: mtime, file_size: size} end)

      {:error, _} ->
        :ok
    end

    state = %{state | workspace: %{state.workspace | pending_conflict: nil}}
    {:handled, EditorState.clear_status(state)}
  end

  def handle_key(%{workspace: %{pending_conflict: {_, _}}} = state, _cp, _mods) do
    # Swallow all other keys while conflict prompt is active
    {:handled, state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
