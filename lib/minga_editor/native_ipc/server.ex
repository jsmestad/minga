defmodule MingaEditor.NativeIPC.Server do
  @moduledoc """
  Publishes one authenticated AF_UNIX endpoint generation for a bundled macOS app.
  """

  use GenServer
  import Bitwise

  alias MingaEditor.NativeIPC.Endpoint
  alias MingaEditor.NativeIPC.Identity
  alias MingaEditor.NativeIPC.Server.State

  @runtime_directory_name "com.minga.editor"

  @typedoc "Server option."
  @type start_opt ::
          {:name, GenServer.name() | nil}
          | {:task_supervisor, atom()}
          | {:runtime_parent, String.t()}
          | {:runtime_dir, String.t()}
          | {:app_instance_id, String.t()}
          | {:app_pid, pos_integer()}
          | {:euid, non_neg_integer()}
          | {:launch_nonce, String.t() | nil}
          | {:wait_tracker, GenServer.server()}
          | {:editor_server, GenServer.server()}
          | {:open_wait,
             (String.t(), boolean(), String.t(), pid(), GenServer.server(), GenServer.server() ->
                :ok | {:error, term()})}
          | {:open_request, (String.t(), boolean(), GenServer.server() -> :ok | {:error, term()})}
          | {:kill_checker, (pos_integer() -> boolean())}

  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Returns the published identity for tests and diagnostics."
  @spec identity(GenServer.server()) :: Identity.t()
  def identity(server \\ __MODULE__), do: GenServer.call(server, :identity)

  @impl true
  @spec init(keyword()) :: {:ok, State.t()} | {:stop, term()}
  def init(opts) do
    Process.flag(:trap_exit, true)

    task_supervisor = Keyword.fetch!(opts, :task_supervisor)

    connection_opts =
      Keyword.take(opts, [:wait_tracker, :editor_server, :open_wait, :open_request, :kill_checker])

    with {:ok, base} <- identity_base(opts),
         {:ok, runtime_parent} <- runtime_parent(opts),
         :ok <- validate_private_parent(runtime_parent, base.euid),
         {:ok, runtime_dir} <- runtime_dir(opts, runtime_parent),
         :ok <- prepare_runtime_dir(runtime_dir, base.euid),
         {:ok, endpoint} <- Endpoint.open(runtime_dir: runtime_dir, identity_base: base) do
      finalize_endpoint(endpoint, task_supervisor, connection_opts)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), State.t()) :: {:reply, term(), State.t()}
  def handle_call(:identity, _from, state), do: {:reply, state.endpoint.identity, state}

  @impl true
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()} | {:stop, term(), State.t()}
  def handle_info({:EXIT, acceptor, reason}, %State{acceptor: acceptor} = state) do
    {:stop, {:acceptor_exited, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), State.t()) :: :ok
  def terminate(_reason, state) do
    Endpoint.close(state.endpoint)
    :ok
  end

  @spec identity_base(keyword()) :: {:ok, map()} | {:error, term()}
  defp identity_base(opts) do
    with {:ok, app_instance_id} <-
           required_string(opts, :app_instance_id, "MINGA_APP_INSTANCE_ID"),
         {:ok, app_pid} <- required_positive_integer(opts, :app_pid, "MINGA_APP_PID"),
         {:ok, euid} <- required_integer(opts, :euid, "MINGA_APP_EUID") do
      launch_nonce = Keyword.get(opts, :launch_nonce, System.get_env("MINGA_LAUNCH_NONCE"))

      {:ok,
       %{
         app_instance_id: app_instance_id,
         core_instance_id: random_secret(16),
         app_pid: app_pid,
         euid: euid,
         launch_nonce: blank_to_nil(launch_nonce),
         token: random_secret(32)
       }}
    end
  end

  @spec required_string(keyword(), atom(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp required_string(opts, key, env) do
    case Keyword.get(opts, key, System.get_env(env)) do
      value when is_binary(value) and byte_size(value) >= 16 -> {:ok, value}
      _other -> {:error, {:missing_or_invalid_identity, env}}
    end
  end

  @spec required_integer(keyword(), atom(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp required_integer(opts, key, env) do
    case Keyword.get(opts, key, System.get_env(env)) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value when is_binary(value) -> parse_non_negative(value, env)
      _other -> {:error, {:missing_or_invalid_identity, env}}
    end
  end

  @spec required_positive_integer(keyword(), atom(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp required_positive_integer(opts, key, env) do
    case Keyword.get(opts, key, System.get_env(env)) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) -> parse_positive(value, env)
      _other -> {:error, {:missing_or_invalid_identity, env}}
    end
  end

  @spec parse_positive(String.t(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  defp parse_positive(value, env) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:missing_or_invalid_identity, env}}
    end
  end

  @spec parse_non_negative(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp parse_non_negative(value, env) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, {:missing_or_invalid_identity, env}}
    end
  end

  @spec runtime_parent(keyword()) :: {:ok, String.t()} | {:error, term()}
  defp runtime_parent(opts) do
    case Keyword.get(opts, :runtime_parent, System.get_env("MINGA_IPC_RUNTIME_PARENT")) do
      value when is_binary(value) and value != "" -> {:ok, Path.expand(value)}
      _other -> {:error, {:missing_or_invalid_identity, "MINGA_IPC_RUNTIME_PARENT"}}
    end
  end

  @spec runtime_dir(keyword(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp runtime_dir(opts, parent) do
    expected = Path.join(parent, @runtime_directory_name)
    configured = opts |> Keyword.get(:runtime_dir, expected) |> Path.expand()

    if configured == expected do
      {:ok, configured}
    else
      {:error, {:runtime_directory_outside_parent, configured, parent}}
    end
  end

  @spec validate_private_parent(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_private_parent(path, euid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: ^euid, mode: mode}}
      when (mode &&& 0o077) == 0 ->
        :ok

      {:ok, %File.Stat{} = stat} ->
        {:error, {:insecure_runtime_parent, path, stat.type, stat.uid, stat.mode &&& 0o777}}

      {:error, reason} ->
        {:error, {:runtime_parent, path, reason}}
    end
  end

  @spec prepare_runtime_dir(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp prepare_runtime_dir(path, euid) do
    case File.lstat(path) do
      {:ok, _stat} -> validate_private_file(path, :directory, euid, 0o700)
      {:error, :enoent} -> create_runtime_dir(path, euid)
      {:error, reason} -> {:error, {:runtime_directory, reason}}
    end
  end

  @spec create_runtime_dir(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp create_runtime_dir(path, euid) do
    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o700),
         :ok <- validate_private_file(path, :directory, euid, 0o700) do
      :ok
    else
      {:error, :eexist} -> validate_private_file(path, :directory, euid, 0o700)
      {:error, reason} -> {:error, {:runtime_directory, reason}}
    end
  end

  @spec validate_private_file(String.t(), atom(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp validate_private_file(path, expected_type, euid, permissions) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^expected_type, uid: ^euid, mode: mode}}
      when (mode &&& 0o777) == permissions ->
        :ok

      {:ok, %File.Stat{} = stat} ->
        {:error, {:insecure_runtime_entry, path, stat.type, stat.uid, stat.mode &&& 0o777}}

      {:error, reason} ->
        {:error, {:runtime_entry, path, reason}}
    end
  end

  @spec accept_loop(port(), atom(), Identity.t(), keyword()) :: no_return()
  defp accept_loop(listener, task_supervisor, identity, opts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, pid} =
          Task.Supervisor.start_child(task_supervisor, fn ->
            receive do
              {:serve, ^socket} ->
                MingaEditor.NativeIPC.Connection.serve(socket, identity, opts)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:serve, socket})
        accept_loop(listener, task_supervisor, identity, opts)

      {:error, :closed} ->
        exit(:normal)

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp finalize_endpoint(%Endpoint{} = endpoint, task_supervisor, connection_opts) do
    acceptor =
      spawn_link(fn ->
        accept_loop(endpoint.listener, task_supervisor, endpoint.identity, connection_opts)
      end)

    {:ok, State.new(endpoint, acceptor)}
  catch
    kind, reason ->
      Endpoint.close(endpoint)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @spec random_secret(pos_integer()) :: String.t()
  defp random_secret(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil
end
