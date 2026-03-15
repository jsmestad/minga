defmodule Minga.Editor.BufferLifecycle do
  @moduledoc """
  LSP and Git buffer lifecycle helpers for the Editor.

  Handles notifications to the LSP server and Git buffer tracking
  when buffers are opened, changed, saved, or closed. All functions
  are pure state transformations.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Hooks, as: ConfigHooks
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.Modeline
  alias Minga.Editor.State, as: EditorState
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.LSP.Client
  alias Minga.Mode

  @type state :: EditorState.t()

  # ── LSP lifecycle ──────────────────────────────────────────────────────

  @doc "Notifies the LSP server that a buffer was opened."
  @spec lsp_buffer_opened(state(), pid()) :: state()
  def lsp_buffer_opened(state, buffer_pid) do
    new_lsp = DocumentSync.on_buffer_open(state.lsp, buffer_pid)
    state = %{state | lsp: new_lsp}
    state = refresh_lsp_status(state)

    # Schedule a deferred refresh for async LSP initialization.
    # The client starts in :starting, transitions to :initializing,
    # then :ready. The handle_info(:refresh_lsp_status) clause polls
    # until the status stabilizes.
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
    %{state | lsp_status: lsp_status_for_buffer(state, buf)}
  end

  @doc """
  Queries the LSP status for a buffer by calling each attached client.

  Returns the aggregate status: `:ready` if any client is ready,
  `:error` if any crashed, `:initializing`/`:starting` if connecting,
  or `:none` if no LSP clients are attached.
  """
  @spec lsp_status_for_buffer(state(), pid() | nil) :: Modeline.lsp_status()
  def lsp_status_for_buffer(_state, nil), do: :none

  def lsp_status_for_buffer(state, buffer_pid) do
    clients = DocumentSync.clients_for_buffer(state.lsp, buffer_pid)

    case clients do
      [] -> :none
      pids -> pids |> Enum.map(&query_client_status/1) |> aggregate_lsp_status()
    end
  end

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

  # Priority: ready > error > initializing > starting > none
  @spec merge_lsp_status(Client.State.status() | :error, Modeline.lsp_status()) ::
          Modeline.lsp_status()
  defp merge_lsp_status(:ready, _acc), do: :ready
  defp merge_lsp_status(_status, :ready), do: :ready
  defp merge_lsp_status(:error, _acc), do: :error
  defp merge_lsp_status(_status, :error), do: :error
  defp merge_lsp_status(:initializing, _acc), do: :initializing
  defp merge_lsp_status(_status, :initializing), do: :initializing
  defp merge_lsp_status(:starting, _acc), do: :starting
  defp merge_lsp_status(_status, :starting), do: :starting
  defp merge_lsp_status(_status, acc), do: acc

  @doc "Notifies the LSP server that the active buffer changed."
  @spec lsp_buffer_changed(state()) :: state()
  def lsp_buffer_changed(%{buffers: %{active: nil}} = state), do: state

  def lsp_buffer_changed(%{buffers: %{active: buf}, lsp: lsp} = state) do
    new_lsp = DocumentSync.on_buffer_change(lsp, buf)
    %{state | lsp: new_lsp}
  end

  @doc "Runs LSP save and kill notifications after a command."
  @spec lsp_after_command(state(), Mode.command(), pid() | nil) :: state()
  def lsp_after_command(state, cmd, old_buffer) do
    state
    |> lsp_after_save(cmd)
    |> lsp_after_kill(cmd, old_buffer)
  end

  @doc "Notifies the LSP server after a buffer save. Also fires after_save hooks."
  @spec lsp_after_save(state(), Mode.command()) :: state()
  def lsp_after_save(%{buffers: %{active: buf}} = state, cmd) when is_pid(buf) do
    if cmd in [
         :save,
         :force_save,
         {:execute_ex_command, {:save, []}},
         {:execute_ex_command, {:save_quit, []}}
       ] do
      path = BufferServer.file_path(buf)
      if path, do: ConfigHooks.run(:after_save, [buf, path])

      new_lsp = DocumentSync.on_buffer_save(state.lsp, buf)
      %{state | lsp: new_lsp}
    else
      state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  def lsp_after_save(state, _cmd), do: state

  @doc "Notifies the LSP server after a buffer is killed/closed."
  @spec lsp_after_kill(state(), Mode.command(), pid() | nil) :: state()
  def lsp_after_kill(state, cmd, old_buffer)
      when cmd in [:kill_buffer, :quit, :force_quit, {:execute_ex_command, {:quit, []}}] and
             is_pid(old_buffer) do
    if state.buffers.active != old_buffer do
      new_lsp = DocumentSync.on_buffer_close(state.lsp, old_buffer)
      %{state | lsp: new_lsp}
    else
      state
    end
  end

  def lsp_after_kill(state, _cmd, _old_buffer), do: state

  # ── Git buffer lifecycle ───────────────────────────────────────────────

  @doc "Starts a Git buffer tracker for a newly opened file buffer."
  @spec git_buffer_opened(state(), pid()) :: state()
  def git_buffer_opened(state, buffer_pid) do
    with path when is_binary(path) <- BufferServer.file_path(buffer_pid),
         {:ok, git_root} <- Minga.Git.root_for(path) do
      start_git_buffer(state, buffer_pid, git_root, path)
    else
      _ -> state
    end
  end

  @doc "Notifies the Git buffer tracker that the active buffer changed."
  @spec git_buffer_changed(state()) :: state()
  def git_buffer_changed(%{buffers: %{active: nil}} = state), do: state

  def git_buffer_changed(%{buffers: %{active: buf}} = state) do
    case Map.get(state.git_buffers, buf) do
      nil -> state
      git_pid -> git_buffer_update(state, buf, git_pid)
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec start_git_buffer(state(), pid(), String.t(), String.t()) :: state()
  defp start_git_buffer(state, buffer_pid, git_root, path) do
    {content, _cursor} = BufferServer.content_and_cursor(buffer_pid)

    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {GitBuffer, git_root: git_root, file_path: path, initial_content: content}
         ) do
      {:ok, git_pid} ->
        rel_path = Path.relative_to(path, git_root)

        Minga.Editor.log_to_messages("Git: tracking #{rel_path}")
        %{state | git_buffers: Map.put(state.git_buffers, buffer_pid, git_pid)}

      {:error, reason} ->
        Minga.Log.warning(:editor, "Failed to start git buffer: #{inspect(reason)}")
        state
    end
  end

  @spec git_buffer_update(state(), pid(), pid()) :: state()
  defp git_buffer_update(state, buf, git_pid) do
    if Process.alive?(git_pid) do
      {content, _cursor} = BufferServer.content_and_cursor(buf)
      GitBuffer.update(git_pid, content)
    end

    state
  end
end
