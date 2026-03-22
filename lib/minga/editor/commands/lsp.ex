defmodule Minga.Editor.Commands.Lsp do
  @moduledoc """
  LSP management commands: info, restart, stop, start.

  Provides user-facing commands for inspecting and controlling
  language server instances attached to the current buffer.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.BufferLifecycle
  alias Minga.Editor.HoverPopup
  alias Minga.Editor.LspActions
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.LSP.Client
  alias Minga.LSP.ServerRegistry
  alias Minga.LSP.Supervisor, as: LSPSupervisor
  alias Minga.LSP.SyncServer
  alias Minga.Picker.WorkspaceSymbolSource
  alias Minga.Tool.Manager, as: ToolManager
  alias Minga.Tool.Recipe
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry

  @type state :: EditorState.t()

  @command_specs [
    {:lsp_info, "Show LSP server status", true},
    {:lsp_restart, "Restart LSP server", true},
    {:lsp_stop, "Stop LSP server", true},
    {:lsp_start, "Start LSP server", true}
  ]

  @doc "Shows LSP server status in the minibuffer."
  @spec execute(state(), :lsp_info | :lsp_restart | :lsp_stop | :lsp_start) :: state()
  def execute(state, :lsp_info) do
    clients = LSPSupervisor.all_clients()

    case clients do
      [] ->
        %{state | status_msg: "No language servers running"}

      _ ->
        markdown = build_lsp_info_markdown(clients)
        vp = state.viewport
        popup = HoverPopup.new(markdown, div(vp.rows, 2), div(vp.cols, 4))
        popup = HoverPopup.focus(popup)
        %{state | hover_popup: popup}
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
          maybe_broadcast_buffer_opened(buf)
          {[{:ok, config.name} | results], st}

        {:error, reason} ->
          Minga.Log.warning(:lsp, "Failed to start #{config.name}: #{inspect(reason)}")
          {[{:error, config.name, reason} | results], st}
      end
    end)
  end

  # ── Private: helpers ─────────────────────────────────────────────────────

  # Re-broadcasts :buffer_opened so SyncServer attaches clients for newly
  # started LSP servers.
  @spec maybe_broadcast_buffer_opened(pid()) :: :ok
  defp maybe_broadcast_buffer_opened(buf) do
    path = BufferServer.file_path(buf)

    if path do
      Minga.Events.broadcast(:buffer_opened, %Minga.Events.BufferEvent{buffer: buf, path: path})
    end

    :ok
  end

  @spec clients_and_keys_for_active(state()) :: [{atom(), {atom(), String.t()}}]
  defp clients_and_keys_for_active(%{buffers: %{active: buf}} = _state) do
    clients = SyncServer.clients_for_buffer(buf)
    Enum.flat_map(clients, &client_name_and_key/1)
  end

  @spec client_name_and_key(pid()) :: [{atom(), {atom(), String.t()}}]
  defp client_name_and_key(pid) do
    name = Client.server_name(pid)
    root = Client.root_path(pid)
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

  @spec build_lsp_info_markdown([pid()]) :: String.t()
  defp build_lsp_info_markdown(clients) do
    header = "# LSP Servers\n\n"

    rows =
      Enum.map_join(clients, "\n\n", fn pid ->
        info = gather_client_info(pid)
        tool_info = tool_info_for_server(info.name)

        """
        **#{info.name}** `#{info.status}`
        - Root: `#{info.root}`
        - Encoding: #{info.encoding}
        - Uptime: #{info.uptime}#{tool_info}\
        """
      end)

    header <> rows
  end

  # Returns a markdown snippet with tool manager info for a server,
  # or empty string if the server isn't managed by Minga.
  @spec tool_info_for_server(atom()) :: String.t()
  defp tool_info_for_server(server_name) do
    command = Atom.to_string(server_name)

    case RecipeRegistry.for_command(command) do
      nil -> ""
      recipe -> format_tool_info(recipe)
    end
  end

  @spec format_tool_info(Recipe.t()) :: String.t()
  defp format_tool_info(recipe) do
    case ToolManager.get_installation(recipe.name) do
      nil ->
        "\n- Tool: not managed (system install)"

      inst ->
        update_info = check_update_info(recipe, inst.version)
        "\n- Tool: managed by Minga (v#{inst.version})#{update_info}"
    end
  end

  # Returns cached update info if ToolManager has checked recently.
  # Does not make network calls; the Editor GenServer must never block.
  @spec check_update_info(Recipe.t(), String.t()) :: String.t()
  defp check_update_info(_recipe, _installed_version) do
    # TODO: wire to ToolManager.cached_latest_version/1 once it exposes
    # an ETS-backed per-tool version cache from check_updates results
    ""
  end

  @spec gather_client_info(pid()) :: map()
  defp gather_client_info(pid) do
    name = Client.server_name(pid)
    status = Client.status(pid)
    encoding = Client.encoding(pid)
    root = Client.root_path(pid)
    uptime = pid |> Client.started_at() |> format_uptime()
    %{name: name, status: status, encoding: encoding, root: root, uptime: uptime}
  catch
    :exit, _ -> %{name: "unknown", status: :dead, encoding: "?", root: "?", uptime: "?"}
  end

  @spec format_uptime(integer() | nil) :: String.t()
  defp format_uptime(nil), do: "unknown"

  defp format_uptime(started_at) do
    (System.monotonic_time(:second) - started_at) |> format_elapsed()
  end

  @spec format_elapsed(integer()) :: String.t()
  defp format_elapsed(s) when s < 60, do: "#{s}s"
  defp format_elapsed(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp format_elapsed(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  @impl Minga.Command.Provider
  def __commands__ do
    standard =
      Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
        %Minga.Command{
          name: name,
          description: desc,
          requires_buffer: requires_buffer,
          execute: fn state -> execute(state, name) end
        }
      end)

    lsp_actions = [
      %Minga.Command{
        name: :goto_definition,
        description: "Go to definition",
        requires_buffer: true,
        execute: &LspActions.goto_definition/1
      },
      %Minga.Command{
        name: :hover,
        description: "Hover documentation",
        requires_buffer: true,
        execute: &LspActions.hover/1
      },
      %Minga.Command{
        name: :find_references,
        description: "Find all references",
        requires_buffer: true,
        execute: &LspActions.find_references/1
      },
      %Minga.Command{
        name: :code_action,
        description: "Code actions",
        requires_buffer: true,
        execute: &LspActions.code_action/1
      },
      %Minga.Command{
        name: :rename_symbol,
        description: "Rename symbol",
        requires_buffer: true,
        execute: &LspActions.prepare_rename/1
      },
      %Minga.Command{
        name: :goto_type_definition,
        description: "Go to type definition",
        requires_buffer: true,
        execute: &LspActions.goto_type_definition/1
      },
      %Minga.Command{
        name: :goto_implementation,
        description: "Go to implementation",
        requires_buffer: true,
        execute: &LspActions.goto_implementation/1
      },
      %Minga.Command{
        name: :document_symbols,
        description: "Document symbols",
        requires_buffer: true,
        execute: &LspActions.document_symbols/1
      },
      %Minga.Command{
        name: :selection_expand,
        description: "Smart selection expand",
        requires_buffer: true,
        execute: &LspActions.selection_expand/1
      },
      %Minga.Command{
        name: :selection_shrink,
        description: "Smart selection shrink",
        requires_buffer: true,
        execute: &LspActions.selection_shrink/1
      },
      %Minga.Command{
        name: :call_hierarchy,
        description: "Call hierarchy (incoming)",
        requires_buffer: true,
        execute: &LspActions.prepare_call_hierarchy/1
      },
      %Minga.Command{
        name: :call_hierarchy_outgoing,
        description: "Call hierarchy (outgoing)",
        requires_buffer: true,
        execute: &LspActions.prepare_outgoing_call_hierarchy/1
      },
      %Minga.Command{
        name: :workspace_symbols,
        description: "Search workspace symbols",
        requires_buffer: true,
        execute: fn state ->
          PickerUI.open(state, WorkspaceSymbolSource)
        end
      }
    ]

    standard ++ lsp_actions
  end
end
