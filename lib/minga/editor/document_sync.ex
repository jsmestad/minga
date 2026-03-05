defmodule Minga.Editor.DocumentSync do
  @moduledoc """
  Synchronizes editor buffers with LSP servers.

  Provides functions the Editor calls at key lifecycle points:

  * `on_buffer_open/2` — when a file is opened, starts language servers
    and sends `textDocument/didOpen`
  * `on_buffer_change/2` — when buffer content changes, debounces and
    sends `textDocument/didChange`
  * `on_buffer_save/2` — when a file is saved, sends `textDocument/didSave`
  * `on_buffer_close/2` — when a buffer is closed, sends
    `textDocument/didClose`

  Tracks the mapping of `buffer_pid => [client_pid]` so each buffer knows
  which language servers are attached to it.

  ## Debouncing

  `didChange` notifications are debounced per-buffer — rapid edits (typing,
  delete, paste) coalesce into a single notification after 150ms of quiet.
  This prevents flooding the language server with changes on every keystroke.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.LSP.Client
  alias Minga.LSP.RootDetector
  alias Minga.LSP.ServerRegistry
  alias Minga.LSP.Supervisor, as: LSPSupervisor

  require Logger

  @debounce_ms 150

  @typedoc "LSP bridge state tracked in the Editor."
  @type t :: %{
          buffer_clients: %{pid() => [pid()]},
          debounce_timers: %{pid() => reference()}
        }

  @doc "Returns initial LSP bridge state."
  @spec new() :: t()
  def new do
    %{buffer_clients: %{}, debounce_timers: %{}}
  end

  @doc """
  Called when a buffer is opened. Detects filetype, starts language servers,
  and sends `textDocument/didOpen` to each.

  Returns updated LSP bridge state.
  """
  @spec on_buffer_open(t(), pid(), keyword()) :: t()
  def on_buffer_open(lsp_state, buffer_pid, opts \\ []) do
    lsp_supervisor = Keyword.get(opts, :lsp_supervisor, LSPSupervisor)
    client_opts = Keyword.take(opts, [:diagnostics])

    filetype = BufferServer.filetype(buffer_pid)
    file_path = BufferServer.file_path(buffer_pid)

    case file_path do
      nil ->
        lsp_state

      path ->
        configs = ServerRegistry.servers_for(filetype)
        uri = path_to_uri(path)
        {content, _cursor} = BufferServer.content_and_cursor(buffer_pid)
        language_id = to_string(filetype)

        clients =
          configs
          |> Enum.map(fn config ->
            root = RootDetector.find_root(path, config.root_markers)
            LSPSupervisor.ensure_client(lsp_supervisor, config, root, client_opts)
          end)
          |> Enum.filter(fn
            {:ok, _pid} -> true
            _ -> false
          end)
          |> Enum.map(fn {:ok, pid} ->
            Client.did_open(pid, uri, language_id, content)
            pid
          end)

        %{lsp_state | buffer_clients: Map.put(lsp_state.buffer_clients, buffer_pid, clients)}
    end
  end

  @doc """
  Called when a buffer's content changes. Debounces and sends
  `textDocument/didChange` to all attached clients.

  Call this after any editing operation (insert, delete, paste, undo, etc.).
  Returns updated LSP bridge state.
  """
  @spec on_buffer_change(t(), pid()) :: t()
  def on_buffer_change(lsp_state, buffer_pid) do
    clients = Map.get(lsp_state.buffer_clients, buffer_pid, [])

    case clients do
      [] ->
        lsp_state

      _ ->
        # Cancel any existing debounce timer for this buffer
        lsp_state = cancel_debounce(lsp_state, buffer_pid)

        # Schedule a new debounced didChange
        timer =
          Process.send_after(
            self(),
            {:lsp_did_change, buffer_pid},
            @debounce_ms
          )

        %{lsp_state | debounce_timers: Map.put(lsp_state.debounce_timers, buffer_pid, timer)}
    end
  end

  @doc """
  Called when the debounce timer fires. Actually sends `didChange` to all
  attached clients with the buffer's current content.

  Returns updated LSP bridge state.
  """
  @spec flush_did_change(t(), pid()) :: t()
  def flush_did_change(lsp_state, buffer_pid) do
    clients = Map.get(lsp_state.buffer_clients, buffer_pid, [])
    timers = Map.delete(lsp_state.debounce_timers, buffer_pid)
    lsp_state = %{lsp_state | debounce_timers: timers}

    notify_clients_change(clients, buffer_pid)
    lsp_state
  end

  @doc """
  Called when a buffer is saved. Sends `textDocument/didSave` to all
  attached clients.
  """
  @spec on_buffer_save(t(), pid()) :: t()
  def on_buffer_save(lsp_state, buffer_pid) do
    clients = Map.get(lsp_state.buffer_clients, buffer_pid, [])
    notify_clients(clients, buffer_pid, &Client.did_save/2)
    lsp_state
  end

  @doc """
  Called when a buffer is closed. Sends `textDocument/didClose` to all
  attached clients and removes the buffer from tracking.

  Returns updated LSP bridge state.
  """
  @spec on_buffer_close(t(), pid()) :: t()
  def on_buffer_close(lsp_state, buffer_pid) do
    clients = Map.get(lsp_state.buffer_clients, buffer_pid, [])
    notify_clients(clients, buffer_pid, &Client.did_close/2)

    lsp_state = cancel_debounce(lsp_state, buffer_pid)

    %{
      lsp_state
      | buffer_clients: Map.delete(lsp_state.buffer_clients, buffer_pid),
        debounce_timers: Map.delete(lsp_state.debounce_timers, buffer_pid)
    }
  end

  @doc """
  Returns the LSP client pids attached to a buffer.
  """
  @spec clients_for_buffer(t(), pid()) :: [pid()]
  def clients_for_buffer(lsp_state, buffer_pid) do
    Map.get(lsp_state.buffer_clients, buffer_pid, [])
  end

  @doc """
  Converts a file system path to a `file://` URI.

  ## Examples

      iex> Minga.Editor.DocumentSync.path_to_uri("/tmp/test.ex")
      "file:///tmp/test.ex"
  """
  @spec path_to_uri(String.t()) :: String.t()
  def path_to_uri(path) when is_binary(path) do
    "file://" <> Path.expand(path)
  end

  @doc """
  Converts a `file://` URI back to a file system path.

  ## Examples

      iex> Minga.Editor.DocumentSync.uri_to_path("file:///tmp/test.ex")
      "/tmp/test.ex"
  """
  @spec uri_to_path(String.t()) :: String.t()
  def uri_to_path("file://" <> path), do: path
  def uri_to_path(uri), do: uri

  # ── Private ────────────────────────────────────────────────────────────────

  @spec notify_clients([pid()], pid(), (pid(), String.t() -> :ok)) :: :ok
  defp notify_clients([], _buffer_pid, _fun), do: :ok

  defp notify_clients(clients, buffer_pid, fun) do
    uri = buffer_uri(buffer_pid)
    if uri, do: send_to_alive_clients(clients, fn c -> fun.(c, uri) end)
    :ok
  end

  @spec notify_clients_change([pid()], pid()) :: :ok
  defp notify_clients_change([], _buffer_pid), do: :ok

  defp notify_clients_change(clients, buffer_pid) do
    with true <- Process.alive?(buffer_pid),
         uri when is_binary(uri) <- buffer_uri(buffer_pid) do
      {content, _cursor} = BufferServer.content_and_cursor(buffer_pid)
      send_to_alive_clients(clients, fn c -> Client.did_change(c, uri, content) end)
    end

    :ok
  end

  @spec buffer_uri(pid()) :: String.t() | nil
  defp buffer_uri(buffer_pid) do
    case BufferServer.file_path(buffer_pid) do
      nil -> nil
      path -> path_to_uri(path)
    end
  end

  @spec send_to_alive_clients([pid()], (pid() -> term())) :: :ok
  defp send_to_alive_clients(clients, fun) do
    Enum.each(clients, fn client ->
      if Process.alive?(client), do: fun.(client)
    end)
  end

  @spec cancel_debounce(t(), pid()) :: t()
  defp cancel_debounce(lsp_state, buffer_pid) do
    case Map.get(lsp_state.debounce_timers, buffer_pid) do
      nil ->
        lsp_state

      timer ->
        Process.cancel_timer(timer)
        %{lsp_state | debounce_timers: Map.delete(lsp_state.debounce_timers, buffer_pid)}
    end
  end
end
