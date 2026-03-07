defmodule Minga.Input.ConflictPrompt do
  @moduledoc """
  Input handler for the file-changed-on-disk conflict prompt.

  When a buffer's file has been modified externally and the user hasn't
  responded yet, this handler intercepts all keys. `r` reloads the buffer
  from disk, `k` keeps the local version, and all other keys are swallowed.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Buffer.Server, as: BufferServer

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{pending_conflict: {buf, _path}} = state, ?r, _mods) when is_pid(buf) do
    BufferServer.reload(buf)
    name = Path.basename(BufferServer.file_path(buf) || "buffer")

    {:handled, %{state | pending_conflict: nil, status_msg: "#{name} reloaded (changed on disk)"}}
  end

  def handle_key(%{pending_conflict: {buf, _path}} = state, ?k, _mods) when is_pid(buf) do
    buf_state = :sys.get_state(buf)

    case File.stat(buf_state.file_path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} ->
        :sys.replace_state(buf, fn s -> %{s | mtime: mtime, file_size: size} end)

      {:error, _} ->
        :ok
    end

    {:handled, %{state | pending_conflict: nil, status_msg: nil}}
  end

  def handle_key(%{pending_conflict: {_, _}} = state, _cp, _mods) do
    # Swallow all other keys while conflict prompt is active
    {:handled, state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
