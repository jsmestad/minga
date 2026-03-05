defmodule Minga.LSP.Supervisor do
  @moduledoc """
  DynamicSupervisor managing `LSP.Client` processes.

  One Client per `{server_name, root_path}` — multiple buffers of the same
  filetype in the same project share a single language server instance.
  Deduplication is handled by `ensure_client/2`: if a client already exists
  for the given server+root combination, the existing pid is returned.

  ## Example

      config = %{name: :lexical, command: "lexical", ...}
      {:ok, client} = LSP.Supervisor.ensure_client(config, "/path/to/project")

      # Second call returns the same pid:
      {:ok, ^client} = LSP.Supervisor.ensure_client(config, "/path/to/project")
  """

  use DynamicSupervisor

  alias Minga.LSP.Client
  alias Minga.LSP.ServerRegistry

  require Logger

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc "Starts the LSP supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ensures a Client exists for the given server config and root path.

  If a Client for this `{server_name, root_path}` is already running,
  returns its pid. Otherwise starts a new one under this supervisor.

  Returns `{:error, :not_available}` if the server binary is not on PATH.
  """
  @spec ensure_client(
          GenServer.server(),
          ServerRegistry.server_config(),
          String.t(),
          keyword()
        ) :: {:ok, pid()} | {:error, :not_available | term()}
  def ensure_client(supervisor \\ __MODULE__, server_config, root_path, opts \\ [])
      when is_struct(server_config, Minga.LSP.ServerConfig) and is_binary(root_path) do
    key = {server_config.name, root_path}

    case find_client(supervisor, key) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        start_client(supervisor, server_config, root_path, opts)
    end
  end

  @doc """
  Returns the pid of an existing Client for a server+root, or `:not_found`.
  """
  @spec find_client(GenServer.server(), {atom(), String.t()}) :: {:ok, pid()} | :not_found
  def find_client(supervisor \\ __MODULE__, {server_name, root_path}) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(:not_found, fn {_, pid, _, _} ->
      if is_pid(pid) and Process.alive?(pid) do
        try do
          if Client.server_name(pid) == server_name and
               GenServer.call(pid, :root_path) == root_path do
            {:ok, pid}
          end
        catch
          :exit, _ -> nil
        end
      end
    end)
  end

  @doc """
  Returns all running Client pids.
  """
  @spec all_clients(GenServer.server()) :: [pid()]
  def all_clients(supervisor \\ __MODULE__) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.filter(fn {_, pid, _, _} -> is_pid(pid) and Process.alive?(pid) end)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end

  # ── Supervisor Callbacks ───────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec start_client(
          GenServer.server(),
          ServerRegistry.server_config(),
          String.t(),
          keyword()
        ) :: {:ok, pid()} | {:error, :not_available | term()}
  defp start_client(supervisor, server_config, root_path, opts) do
    if ServerRegistry.available?(server_config) do
      client_opts =
        [server_config: server_config, root_path: root_path] ++
          Keyword.take(opts, [:diagnostics])

      child_spec = {Client, client_opts}

      case DynamicSupervisor.start_child(supervisor, child_spec) do
        {:ok, pid} ->
          Logger.info("Started LSP client #{server_config.name} for #{root_path}")

          {:ok, pid}

        {:error, reason} ->
          Logger.error("Failed to start LSP client #{server_config.name}: #{inspect(reason)}")

          {:error, reason}
      end
    else
      {:error, :not_available}
    end
  end
end
