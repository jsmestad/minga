defmodule MingaEditor.NativeIPC.Server do
  @moduledoc """
  Publishes one authenticated AF_UNIX endpoint generation for a bundled macOS app.
  """

  use GenServer
  import Bitwise

  alias MingaEditor.NativeIPC.Identity
  alias MingaEditor.NativeIPC.Server.State

  @max_frame 65_536
  @descriptor_version 1
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
         {:ok, {listener, descriptor_path, identity}} <- open_endpoint(runtime_dir, base) do
      finalize_endpoint(listener, task_supervisor, identity, connection_opts, descriptor_path)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), State.t()) :: {:reply, term(), State.t()}
  def handle_call(:identity, _from, state), do: {:reply, state.identity, state}

  @impl true
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()} | {:stop, term(), State.t()}
  def handle_info({:EXIT, acceptor, reason}, %State{acceptor: acceptor} = state) do
    {:stop, {:acceptor_exited, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), State.t()) :: :ok
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listener)
    _ = File.rm(state.identity.socket_path)
    remove_descriptor_if_current(state.descriptor_path, state.identity.core_instance_id)
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

  @spec build_identity(map(), String.t()) :: Identity.t()
  defp build_identity(base, socket_path) do
    Identity.new(
      app_instance_id: base.app_instance_id,
      core_instance_id: base.core_instance_id,
      app_pid: base.app_pid,
      euid: base.euid,
      launch_nonce: base.launch_nonce,
      socket_path: socket_path,
      token: base.token
    )
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

  @spec listen(String.t()) :: {:ok, port()} | {:error, term()}
  defp listen(socket_path) do
    :gen_tcp.listen(0, [
      :binary,
      {:ifaddr, {:local, socket_path}},
      {:active, false},
      {:packet, 4},
      {:packet_size, @max_frame},
      {:reuseaddr, true}
    ])
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

  @spec publish_descriptor(String.t(), Identity.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp publish_descriptor(path, identity, euid) do
    temp = path <> ".tmp-#{random_secret(8)}"

    with :ok <-
           File.write(
             temp,
             JSON.encode!(Identity.descriptor(identity, @descriptor_version)) <> "\n",
             [:exclusive]
           ),
         :ok <- File.chmod(temp, 0o600),
         :ok <- validate_private_file(temp, :regular, euid, 0o600) do
      publish_current_descriptor(path, temp, identity, euid)
    else
      {:error, _reason} = error -> remove_temp_descriptor(temp, error)
    end
  end

  defp open_endpoint(runtime_dir, base) do
    socket_path = random_socket_path(runtime_dir)

    with {:ok, listener} <- listen(socket_path) do
      with :ok <- File.chmod(socket_path, 0o600),
           :ok <- validate_private_file(socket_path, :other, base.euid, 0o600),
           identity = build_identity(base, socket_path),
           descriptor_path = Path.join(runtime_dir, "current.json"),
           :ok <- publish_descriptor(descriptor_path, identity, base.euid) do
        {:ok, {listener, descriptor_path, identity}}
      else
        {:error, _reason} = error ->
          rollback_listener_socket(listener, socket_path)
          error
      end
    end
  end

  defp finalize_endpoint(listener, task_supervisor, identity, connection_opts, descriptor_path) do
    acceptor =
      spawn_link(fn -> accept_loop(listener, task_supervisor, identity, connection_opts) end)

    {:ok, State.new(listener, acceptor, descriptor_path, identity)}
  catch
    kind, reason ->
      rollback_published_endpoint(descriptor_path, identity, listener)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp publish_current_descriptor(path, temp, identity, euid) do
    case File.rename(temp, path) do
      :ok ->
        case validate_private_file(path, :regular, euid, 0o600) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            remove_descriptor_if_current(path, identity.core_instance_id)
            error
        end

      {:error, _reason} = error ->
        remove_temp_descriptor(temp, error)
    end
  end

  defp remove_temp_descriptor(temp, error) do
    _ = File.rm(temp)
    error
  end

  defp rollback_published_endpoint(descriptor_path, identity, listener) do
    remove_descriptor_if_current(descriptor_path, identity.core_instance_id)
    rollback_listener_socket(listener, identity.socket_path)
  end

  defp rollback_listener_socket(listener, socket_path) do
    _ = :gen_tcp.close(listener)
    _ = File.rm(socket_path)
    :ok
  end

  @spec remove_descriptor_if_current(String.t(), String.t()) :: :ok
  defp remove_descriptor_if_current(path, core_instance_id) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"core_instance_id" => ^core_instance_id}} <- JSON.decode(contents) do
      _ = File.rm(path)
    end

    :ok
  end

  @spec random_socket_path(String.t()) :: String.t()
  defp random_socket_path(runtime_dir),
    do: Path.join(runtime_dir, "control-#{random_secret(12)}.sock")

  @spec random_secret(pos_integer()) :: String.t()
  defp random_secret(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil
end
