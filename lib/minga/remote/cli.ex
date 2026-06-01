defmodule Minga.Remote.CLI do
  @moduledoc "CLI handlers for remote agent session subcommands."

  alias Minga.Remote.Bootstrap
  alias Minga.Remote.ControlEndpoint
  alias Minga.Remote.SessionURL

  @type attach_result :: Bootstrap.attach_result()

  @doc "Bootstraps a remote session and stores it for editor startup attach."
  @spec attach(String.t()) :: {:ok, attach_result()} | {:error, String.t()}
  def attach(url) when is_binary(url) do
    with {:ok, parsed} <- parse_session_url(url),
         {:ok, result} <- bootstrap().attach(parsed) do
      Application.put_env(:minga, :pending_remote_attach, result)
      {:ok, result}
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @doc "Prints sessions for a remote host URL."
  @spec sessions(String.t()) :: :ok | {:error, String.t()}
  def sessions(url) when is_binary(url) do
    with {:ok, parsed} <- parse_host_url(url),
         {:ok, rows} <- bootstrap().sessions(parsed) do
      print_sessions(rows)
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @doc "Stops the session for a remote working-directory URL."
  @spec kill_session(String.t()) :: :ok | {:error, String.t()}
  def kill_session(url) when is_binary(url) do
    with {:ok, parsed} <- parse_session_url(url),
         :ok <- bootstrap().kill_session(parsed) do
      IO.puts("Stopped remote session for #{parsed.path}")
      :ok
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @doc "Detaches the local frontend from the current remote session."
  @spec detach() :: :ok | {:error, String.t()}
  def detach do
    detach_running_editor(Process.whereis(MingaEditor))
  end

  @spec detach_running_editor(pid() | nil) :: :ok | {:error, String.t()}
  defp detach_running_editor(nil) do
    case ControlEndpoint.read_node() do
      {:ok, node} ->
        case connect_control_node(node) do
          :ok ->
            :ok = :erpc.call(node, Minga.API, :execute, [:detach_remote_session], 10_000)
            Application.delete_env(:minga, :pending_remote_attach)
            IO.puts("Detached local frontend; remote session keeps running.")
            :ok

          {:error, reason} ->
            {:error, "failed to connect to local frontend: #{inspect(reason)}"}
        end

      {:error, :not_found} ->
        {:error,
         "no local frontend control endpoint available; remote sessions keep running on the server"}

      {:error, reason} ->
        {:error, "failed to read local frontend control endpoint: #{inspect(reason)}"}
    end
  catch
    :exit, reason -> {:error, "failed to detach local frontend: #{inspect(reason)}"}
  end

  defp detach_running_editor(_editor) do
    :ok = Minga.API.execute(:detach_remote_session)
    Application.delete_env(:minga, :pending_remote_attach)
    IO.puts("Detached local frontend; remote session keeps running.")
    :ok
  catch
    :exit, reason -> {:error, "failed to detach local frontend: #{inspect(reason)}"}
  end

  @doc "Connects the running editor to a pending remote attach, if one exists."
  @spec connect_pending_editor_attach() :: :ok | {:error, term()} | :none
  def connect_pending_editor_attach do
    case Application.get_env(:minga, :pending_remote_attach) do
      %Bootstrap{} = result ->
        case connect_editor(result) do
          :ok ->
            Application.delete_env(:minga, :pending_remote_attach)
            :ok

          {:error, _} = error ->
            error
        end

      _other ->
        :none
    end
  end

  @spec parse_session_url(String.t()) :: {:ok, SessionURL.t()} | {:error, term()}
  def parse_session_url(url), do: SessionURL.parse(url, require_path?: true)

  @spec parse_host_url(String.t()) :: {:ok, SessionURL.t()} | {:error, term()}
  def parse_host_url(url), do: SessionURL.parse(url, require_path?: false)

  @spec bootstrap() :: module()
  defp bootstrap do
    Application.get_env(:minga, :remote_bootstrap, Bootstrap)
  end

  @spec connect_editor(Bootstrap.attach_result()) :: :ok | {:error, term()}
  defp connect_editor(result) do
    case wait_for_editor(50, 40) do
      :ok ->
        Minga.API.execute(
          {:connect_remote_session,
           %{
             server_name: result.server_name,
             session_id: result.session_id,
             pid: result.pid,
             token: result.token
           }}
        )

      :timeout ->
        {:error, "editor did not start for remote attach"}
    end
  end

  @spec connect_control_node(node()) :: :ok | {:error, term()}
  defp connect_control_node(node) when is_atom(node) do
    case Node.connect(node) do
      true -> :ok
      false -> {:error, {:node_connect_failed, node}}
      :ignored -> {:error, :distribution_not_started}
    end
  end

  @spec wait_for_editor(non_neg_integer(), non_neg_integer()) :: :ok | :timeout
  defp wait_for_editor(_interval, 0), do: :timeout

  defp wait_for_editor(interval, retries) do
    case Process.whereis(MingaEditor) do
      nil ->
        receive do
        after
          interval -> wait_for_editor(interval, retries - 1)
        end

      _pid ->
        :ok
    end
  end

  @spec print_sessions([Bootstrap.session_row()]) :: :ok
  defp print_sessions([]) do
    IO.puts("No remote sessions.")
    :ok
  end

  defp print_sessions(rows) do
    Enum.each(rows, fn row ->
      IO.puts("#{row.session_id}\t#{row.status}\t#{row.workdir || "-"}\t#{row.recent || ""}")
    end)

    :ok
  end

  @spec format_error(term()) :: String.t()
  defp format_error(:invalid_url), do: "expected ssh://[user@]host[:port]/path"
  defp format_error(:missing_path), do: "remote session URL requires a server-side path"
  defp format_error(reason), do: inspect(reason)
end
