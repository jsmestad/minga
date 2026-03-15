defmodule Minga.Editor.BufferLifecycle do
  @moduledoc """
  LSP status tracking and post-command lifecycle helpers for the Editor.

  LSP document synchronization (didOpen, didChange, didSave, didClose) is
  handled by `Minga.LSP.SyncServer` via the event bus. This module retains
  only the LSP status queries (for the modeline indicator) and the
  post-command hook that broadcasts `:buffer_saved`.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Modeline
  alias Minga.Editor.State, as: EditorState
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer
  alias Minga.Mode

  @type state :: EditorState.t()

  # ── LSP status ─────────────────────────────────────────────────────────

  @doc """
  Refreshes the cached LSP status for the active buffer and schedules
  a deferred poll for async LSP initialization.

  Called when a buffer is opened so the modeline shows the LSP indicator.
  """
  @spec lsp_buffer_opened(state(), pid()) :: state()
  def lsp_buffer_opened(state, _buffer_pid) do
    state = refresh_lsp_status(state)

    if state.lsp_status in [:starting, :initializing, :none] do
      Process.send_after(self(), :refresh_lsp_status, 500)
    end

    state
  end

  @doc """
  Refreshes the cached LSP status for the active buffer.

  Call this when LSP lifecycle events arrive (client connected,
  initialized, crashed) to keep the modeline indicator current
  without querying on every render frame.
  """
  @spec refresh_lsp_status(state()) :: state()
  def refresh_lsp_status(%{buffers: %{active: nil}} = state), do: %{state | lsp_status: :none}

  def refresh_lsp_status(%{buffers: %{active: buf}} = state) do
    %{state | lsp_status: lsp_status_for_buffer(buf)}
  end

  @doc """
  Queries the LSP status for a buffer by calling each attached client.

  Returns the aggregate status: `:ready` if any client is ready,
  `:error` if any crashed, `:initializing`/`:starting` if connecting,
  or `:none` if no LSP clients are attached.
  """
  @spec lsp_status_for_buffer(pid() | nil) :: Modeline.lsp_status()
  def lsp_status_for_buffer(nil), do: :none

  def lsp_status_for_buffer(buffer_pid) do
    clients = SyncServer.clients_for_buffer(buffer_pid)

    case clients do
      [] -> :none
      pids -> pids |> Enum.map(&query_client_status/1) |> aggregate_lsp_status()
    end
  end

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
  def lsp_after_save(%{buffers: %{active: buf}} = state, cmd) when is_pid(buf) do
    if cmd in [
         :save,
         :force_save,
         {:execute_ex_command, {:save, []}},
         {:execute_ex_command, {:save_quit, []}}
       ] do
      path = BufferServer.file_path(buf)

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

  # ── Private ────────────────────────────────────────────────────────────

  @spec query_client_status(pid()) :: Client.State.status() | :error
  defp query_client_status(pid) do
    Client.status(pid)
  catch
    :exit, _ -> :error
  end

  @spec aggregate_lsp_status([Client.State.status() | :error]) :: Modeline.lsp_status()
  defp aggregate_lsp_status(statuses) do
    Enum.reduce(statuses, :none, &merge_lsp_status/2)
  end

  defp merge_lsp_status(:ready, _acc), do: :ready
  defp merge_lsp_status(_status, :ready), do: :ready
  defp merge_lsp_status(:error, _acc), do: :error
  defp merge_lsp_status(_status, :error), do: :error
  defp merge_lsp_status(:initializing, _acc), do: :initializing
  defp merge_lsp_status(_status, :initializing), do: :initializing
  defp merge_lsp_status(:starting, _acc), do: :starting
  defp merge_lsp_status(_status, :starting), do: :starting
  defp merge_lsp_status(_status, acc), do: acc
end
