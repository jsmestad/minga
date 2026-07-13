defmodule MingaEditor.Input.ConflictPrompt do
  @moduledoc """
  Input handler for the file-changed-on-disk conflict prompt.

  When a buffer's file has been modified externally and the user hasn't
  responded yet, this handler intercepts all keys. `r` reloads the buffer
  from disk, `k` keeps the local version, and all other keys are swallowed.

  The conflict prompt lives on `state.shell_runtime.state.modal` as
  `{:conflict, %ModalOverlay.Conflict{}}`. While active, the gate's
  conflict-sticky rule prevents other modals from opening on top.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias Minga.Buffer

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(
        %{shell_runtime: %{state: %{modal: {:conflict, %{buffer: buf}}}}} = state,
        ?r,
        _mods
      )
      when is_pid(buf) do
    Buffer.reload(buf)
    name = Path.basename(Buffer.file_path(buf) || "buffer")

    {:handled,
     state
     |> MingaEditor.Shell.Traditional.ModalWorkflow.dismiss()
     |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("#{name} reloaded (changed on disk)")}
  end

  def handle_key(
        %{shell_runtime: %{state: %{modal: {:conflict, %{buffer: buf}}}}} = state,
        ?k,
        _mods
      )
      when is_pid(buf) do
    Buffer.acknowledge_disk_change(buf)

    {:handled,
     state
     |> MingaEditor.Shell.Traditional.ModalWorkflow.dismiss()
     |> MingaEditor.Shell.Traditional.NoticeWorkflow.dismiss()}
  end

  def handle_key(%{shell_runtime: %{state: %{modal: {:conflict, _}}}} = state, _cp, _mods) do
    # Swallow all other keys while conflict prompt is active
    {:handled, state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
