defmodule Minga.Editor.Commands.Lsp do
  @moduledoc """
  LSP management commands: info, restart, stop, start.

  Provides user-facing commands for inspecting and controlling
  language server instances attached to the current buffer.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.BufferLifecycle
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.State, as: EditorState
  alias Minga.LSP.Client
  alias Minga.LSP.ServerRegistry
  alias Minga.LSP.Supervisor, as: LSPSupervisor

  @type state :: EditorState.t()

  @doc "Shows LSP server status in the minibuffer."
  @spec execute(state(), :lsp_info | :lsp_restart | :lsp_stop | :lsp_start) :: state()
  def execute(state, :lsp_info) do
    clients = LSPSupervisor.all_clients()

    case clients do
      [] ->
        %{state | status_msg: "No language servers running"}

      _ ->
        info = Enum.map_join(clients, " | ", &format_client_info/1)
        %{state | status_msg: "LSP: #{info}"}
    end
  end

  def execute(%{buffers: %{active: nil}} = state, :lsp_restart) do
    %{state | status_msg: "No active buffer"}
  end

  def execute(state, :lsp_restart) do
    case clients_and_keys_for_active(state) do
      [] ->
        %{state | status_msg: "No LSP server for this buffer"}

      client_keys ->
        results = Enum.map(client_keys, &restart_one/1)
        msg = format_results(results, "Restarted", "Failed to restart")
        state = %{state | status_msg: msg}
        BufferLifecycle.refresh_lsp_status(state)
    end
  end

  def execute(%{buffers: %{active: nil}} = state, :lsp_stop) do
    %{state | status_msg: "No active buffer"}
  end

  def execute(state, :lsp_stop) do
    case clients_and_keys_for_active(state) do
      [] ->
        %{state | status_msg: "No LSP server for this buffer"}

      client_keys ->
        results = Enum.map(client_keys, &stop_one/1)
        msg = format_results(results, "Stopped", "Failed to stop")
        state = %{state | status_msg: msg}
        BufferLifecycle.refresh_lsp_status(state)
    end
  end

  def execute(%{buffers: %{active: nil}} = state, :lsp_start) do
    %{state | status_msg: "No active buffer"}
  end

  def execute(state, :lsp_start) do
    buf = state.buffers.active
    filetype = BufferServer.filetype(buf)
    configs = ServerRegistry.available_servers_for(filetype)

    case configs do
      [] ->
        %{state | status_msg: "No LSP server available for #{filetype}"}

      _ ->
        root = Minga.Project.root() || "."
        {results, state} = start_servers(configs, root, state, buf)
        msg = format_results(results, "Started", "Failed to start")
        state = %{state | status_msg: msg}

        # Schedule deferred refresh for async initialization
        Process.send_after(self(), :refresh_lsp_status, 500)
        BufferLifecycle.refresh_lsp_status(state)
    end
  end

  # ── Private: per-client operations ────────────────────────────────────────

  @spec format_client_info(pid()) :: String.t()
  defp format_client_info(pid) do
    name = Client.server_name(pid)
    status = Client.status(pid)
    encoding = Client.encoding(pid)
    "#{name}: #{status} (#{encoding})"
  catch
    :exit, _ -> "unknown: dead"
  end

  @spec restart_one({atom(), {atom(), String.t()}}) :: {:ok, atom()} | {:error, atom(), term()}
  defp restart_one({name, key}) do
    case LSPSupervisor.restart_client(key) do
      {:ok, _pid} ->
        Minga.Log.info(:lsp, "Restarted LSP server #{name}")
        {:ok, name}

      {:error, reason} ->
        Minga.Log.warning(:lsp, "Failed to restart #{name}: #{inspect(reason)}")
        {:error, name, reason}
    end
  end

  @spec stop_one({atom(), {atom(), String.t()}}) :: {:ok, atom()} | {:error, atom(), term()}
  defp stop_one({name, key}) do
    case LSPSupervisor.stop_client(key) do
      :ok ->
        Minga.Log.info(:lsp, "Stopped LSP server #{name}")
        {:ok, name}

      {:error, :not_found} ->
        {:error, name, :not_found}
    end
  end

  @spec start_servers([ServerRegistry.server_config()], String.t(), state(), pid()) ::
          {[{:ok, atom()} | {:error, atom(), term()}], state()}
  defp start_servers(configs, root, state, buf) do
    Enum.reduce(configs, {[], state}, fn config, {results, st} ->
      case LSPSupervisor.ensure_client(config, root) do
        {:ok, _pid} ->
          Minga.Log.info(:lsp, "Started LSP server #{config.name}")
          new_lsp = DocumentSync.on_buffer_open(st.lsp, buf)
          {[{:ok, config.name} | results], %{st | lsp: new_lsp}}

        {:error, reason} ->
          Minga.Log.warning(:lsp, "Failed to start #{config.name}: #{inspect(reason)}")
          {[{:error, config.name, reason} | results], st}
      end
    end)
  end

  # ── Private: helpers ─────────────────────────────────────────────────────

  @spec clients_and_keys_for_active(state()) :: [{atom(), {atom(), String.t()}}]
  defp clients_and_keys_for_active(%{buffers: %{active: buf}} = state) do
    clients = DocumentSync.clients_for_buffer(state.lsp, buf)
    Enum.flat_map(clients, &client_name_and_key/1)
  end

  @spec client_name_and_key(pid()) :: [{atom(), {atom(), String.t()}}]
  defp client_name_and_key(pid) do
    name = Client.server_name(pid)
    root = GenServer.call(pid, :root_path)
    [{name, {name, root}}]
  catch
    :exit, _ -> []
  end

  @spec format_results([{:ok, atom()} | {:error, atom(), term()}], String.t(), String.t()) ::
          String.t()
  defp format_results(results, success_verb, failure_verb) do
    {ok, err} = Enum.split_with(results, &match?({:ok, _}, &1))

    parts =
      Enum.map(ok, fn {:ok, name} -> "#{success_verb} #{name}" end) ++
        Enum.map(err, fn {:error, name, _reason} -> "#{failure_verb} #{name}" end)

    Enum.join(parts, ", ")
  end
end
