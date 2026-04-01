defmodule MingaEditor.BufferLifecycle do
  @moduledoc """
  Post-command lifecycle helpers for the Editor.

  LSP document synchronization (didOpen, didChange, didSave, didClose) is
  handled by `Minga.LSP.SyncServer` via the event bus. LSP status tracking
  is event-driven via `:lsp_status_changed` events from `LSP.Client`.

  This module retains the post-command hook that broadcasts `:buffer_saved`.
  """

  alias Minga.Buffer
  alias MingaEditor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  # ── Post-command lifecycle ─────────────────────────────────────────────

  @doc """
  Runs post-command lifecycle actions.

  After save commands, broadcasts `:buffer_saved` so the event bus
  subscribers (SyncServer, Git.Tracker, file tree, hooks) react.
  """
  @spec lsp_after_command(state(), Mode.command(), pid() | nil) :: state()
  def lsp_after_command(state, cmd, _old_buffer) do
    lsp_after_save(state, cmd)
  end

  @doc "Broadcasts :buffer_saved after save commands."
  @spec lsp_after_save(state(), Mode.command()) :: state()
  def lsp_after_save(%{workspace: %{buffers: %{active: buf}}} = state, cmd) when is_pid(buf) do
    if cmd in [
         :save,
         :force_save,
         {:execute_ex_command, {:save, []}},
         {:execute_ex_command, {:save_quit, []}}
       ] do
      path = Buffer.file_path(buf)

      if path,
        do:
          Minga.Events.broadcast(
            :buffer_saved,
            %Minga.Events.BufferEvent{buffer: buf, path: path}
          )
    end

    state
  rescue
    e ->
      Minga.Log.warning(:editor, "Save event broadcast failed: #{Exception.message(e)}")
      state
  catch
    :exit, _ -> state
  end

  def lsp_after_save(state, _cmd), do: state
end
