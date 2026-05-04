defmodule MingaEditor.Input.ConflictPrompt do
  @moduledoc """
  Input handler for the file-changed-on-disk conflict prompt.

  When a buffer's file has been modified externally and the user hasn't
  responded yet, this handler intercepts all keys. `r` reloads the buffer
  from disk, `k` keeps the local version, and all other keys are swallowed.

  The conflict prompt lives on `state.shell_state.modal` as
  `{:conflict, %ModalOverlay.Conflict{}}`. While active, the gate's
  conflict-sticky rule prevents other modals from opening on top.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias Minga.Buffer
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(
        %{shell_state: %{modal: {:conflict, %{buffer: buf}}}} = state,
        ?r,
        _mods
      )
      when is_pid(buf) do
    Buffer.reload(buf)
    name = Path.basename(Buffer.file_path(buf) || "buffer")

    {:handled,
     state
     |> ModalOverlay.dismiss()
     |> EditorState.set_status("#{name} reloaded (changed on disk)")}
  end

  def handle_key(
        %{shell_state: %{modal: {:conflict, %{buffer: buf}}}} = state,
        ?k,
        _mods
      )
      when is_pid(buf) do
    buf_state = :sys.get_state(buf)

    case File.stat(buf_state.file_path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} ->
        :sys.replace_state(buf, fn s -> %{s | mtime: mtime, file_size: size} end)

      {:error, _} ->
        :ok
    end

    {:handled, state |> ModalOverlay.dismiss() |> EditorState.clear_status()}
  end

  def handle_key(%{shell_state: %{modal: {:conflict, _}}} = state, _cp, _mods) do
    # Swallow all other keys while conflict prompt is active
    {:handled, state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
