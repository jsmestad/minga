defmodule Minga.CLI do
  @moduledoc """
  Command-line interface for Minga.

  Serves as the entry point for both `mix minga <filename>` and the standalone Burrito binary (`./minga <filename>`). In Burrito mode, arguments are fetched via `Burrito.Util.Args.argv/0` which works whether running standalone or under Mix.

  ## Startup view

  By default, Minga boots into the agentic view (controlled by the `:startup_view` config option). CLI flags can override the config:

  - `--editor` forces the traditional file editing view
  - `--no-context` opens the agentic view but skips loading the CLI file argument as preview context
  - `--headless` starts only the services and agent runtime, plus the JSON-RPC Gateway
  """

  alias Burrito.Util.Args
  alias Minga.Distribution.Cookie

  @typedoc "Parsed CLI result."
  @type parsed ::
          {:open, file :: String.t() | nil, flags()}
          | {:error, String.t()}

  @typedoc "CLI flags that override config options."
  @type flags :: %{
          force_editor: boolean(),
          no_context: boolean(),
          config_file: String.t() | nil,
          headless: boolean(),
          minimal: boolean(),
          node_name: String.t() | nil,
          short_name: boolean(),
          cookie: String.t() | nil,
          cookie_file: String.t() | nil,
          gateway_port: pos_integer() | nil,
          gateway_host: String.t() | nil
        }

  @default_flags %{
    force_editor: false,
    no_context: false,
    config_file: nil,
    headless: false,
    minimal: false,
    node_name: nil,
    short_name: false,
    cookie: nil,
    cookie_file: nil,
    gateway_port: nil,
    gateway_host: nil
  }

  @default_gateway_port 4820

  @doc "Main entry point for the CLI."
  @spec main([String.t()]) :: :ok
  def main(args) do
    case parse_args(args) do
      {:open, file, flags} ->
        store_startup_flags(flags)

        case maybe_start_distribution(flags) do
          :ok -> launch(flags, file)
          {:error, message} -> abort_startup(message)
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        System.stop(1)
    end

    :ok
  end

  @doc "Entry point used by the OTP application in release/Burrito mode."
  @spec start_from_cli() :: :ok
  def start_from_cli do
    args = Args.argv()
    main(args)
  end

  @doc "Parses CLI arguments into an action."
  @spec parse_args([String.t()]) :: parsed()
  def parse_args(args) do
    parse_args(args, nil, @default_flags)
  end

  @doc "Returns true when args request headless mode."
  @spec headless_args?([String.t()]) :: boolean()
  def headless_args?(args) do
    Enum.member?(args, "--headless")
  end

  @doc "Returns the startup flags stored by the CLI, or defaults if none were set."
  @spec startup_flags() :: flags()
  def startup_flags do
    Application.get_env(:minga, :cli_startup_flags, @default_flags)
  end

  # ── Argument parsing ────────────────────────────────────────────────────────

  @spec parse_args([String.t()], String.t() | nil, flags()) :: parsed()
  defp parse_args([], file, flags), do: {:open, file, flags}

  defp parse_args(["--help" | _], _file, _flags), do: {:error, usage()}
  defp parse_args(["-h" | _], _file, _flags), do: {:error, usage()}
  defp parse_args(["--version" | _], _file, _flags), do: {:error, "minga #{Minga.version()}"}
  defp parse_args(["-v" | _], _file, _flags), do: {:error, "minga #{Minga.version()}"}

  defp parse_args(["--editor" | rest], file, flags) do
    parse_args(rest, file, %{flags | force_editor: true})
  end

  defp parse_args(["--no-context" | rest], file, flags) do
    parse_args(rest, file, %{flags | no_context: true})
  end

  defp parse_args(["--headless" | rest], file, flags) do
    parse_args(rest, file, %{flags | headless: true})
  end

  defp parse_args(["--sname", <<"--", _::binary>> | _], _file, _flags) do
    {:error, "--sname requires a node name argument, not a flag\n\n#{usage()}"}
  end

  defp parse_args(["--sname", name | rest], file, flags) when is_binary(name) and name != "" do
    parse_args(rest, file, %{flags | node_name: name, short_name: true})
  end

  defp parse_args(["--sname"], _file, _flags) do
    {:error, "--sname requires a node name argument\n\n#{usage()}"}
  end

  defp parse_args(["--name", <<"--", _::binary>> | _], _file, _flags) do
    {:error, "--name requires a node name argument, not a flag\n\n#{usage()}"}
  end

  defp parse_args(["--name", name | rest], file, flags) when is_binary(name) and name != "" do
    parse_args(rest, file, %{flags | node_name: name, short_name: false})
  end

  defp parse_args(["--name"], _file, _flags) do
    {:error, "--name requires a node name argument\n\n#{usage()}"}
  end

  defp parse_args(["--cookie", <<"--", _::binary>> | _], _file, _flags) do
    {:error, "--cookie requires a cookie argument, not a flag\n\n#{usage()}"}
  end

  defp parse_args(["--cookie", cookie | rest], file, flags)
       when is_binary(cookie) and cookie != "" do
    parse_args(rest, file, %{flags | cookie: cookie})
  end

  defp parse_args(["--cookie"], _file, _flags) do
    {:error, "--cookie requires a cookie argument\n\n#{usage()}"}
  end

  defp parse_args(["--cookie-file", <<"--", _::binary>> | _], _file, _flags) do
    {:error, "--cookie-file requires a path argument, not a flag\n\n#{usage()}"}
  end

  defp parse_args(["--cookie-file", path | rest], file, flags)
       when is_binary(path) and path != "" do
    parse_args(rest, file, %{flags | cookie_file: Path.expand(path)})
  end

  defp parse_args(["--cookie-file"], _file, _flags) do
    {:error, "--cookie-file requires a path argument\n\n#{usage()}"}
  end

  defp parse_args(["--host", <<"--", _::binary>> | _], _file, _flags) do
    {:error, "--host requires an IP address argument, not a flag\n\n#{usage()}"}
  end

  defp parse_args(["--host", host | rest], file, flags) when is_binary(host) and host != "" do
    case parse_gateway_ip(host) do
      {:ok, _ip} -> parse_args(rest, file, %{flags | gateway_host: host})
      {:error, _reason} -> {:error, "--host requires a valid IP address\n\n#{usage()}"}
    end
  end

  defp parse_args(["--host"], _file, _flags) do
    {:error, "--host requires an IP address argument\n\n#{usage()}"}
  end

  defp parse_args(["--port", <<"--", _::binary>> | _], _file, _flags) do
    {:error, "--port requires a numeric argument, not a flag\n\n#{usage()}"}
  end

  defp parse_args(["--port", value | rest], file, flags) when is_binary(value) do
    case parse_port(value) do
      {:ok, port} -> parse_args(rest, file, %{flags | gateway_port: port})
      :error -> {:error, "--port requires a TCP port between 1 and 65535\n\n#{usage()}"}
    end
  end

  defp parse_args(["--port"], _file, _flags) do
    {:error, "--port requires a numeric argument\n\n#{usage()}"}
  end

  defp parse_args(["--config", <<"--", _::binary>> | _], _file, _flags) do
    {:error, "--config requires a path argument, not a flag\n\n#{usage()}"}
  end

  defp parse_args(["--config", "" | _], _file, _flags) do
    {:error, "--config requires a non-empty path argument\n\n#{usage()}"}
  end

  defp parse_args(["--config", path | rest], file, flags) when is_binary(path) do
    parse_args(rest, file, %{flags | config_file: Path.expand(path)})
  end

  defp parse_args(["--config"], _file, _flags) do
    {:error, "--config requires a path argument\n\n#{usage()}"}
  end

  defp parse_args(["--minimal" | rest], file, flags) do
    parse_args(rest, file, %{flags | minimal: true})
  end

  defp parse_args([<<"--", _::binary>> = flag | _], _file, _flags) do
    {:error, "unknown flag: #{flag}\n\n#{usage()}"}
  end

  defp parse_args([file_path | rest], _file, flags) do
    parse_args(rest, file_path, flags)
  end

  # ── Launch helpers ──────────────────────────────────────────────────────────

  @spec launch(flags(), String.t() | nil) :: :ok
  defp launch(%{headless: true} = flags, _file) do
    auth_token = gateway_auth_token()

    with {:ok, port} <- gateway_port(flags),
         {:ok, ip} <- gateway_ip(flags) do
      start_headless_gateway(port, ip, auth_token)
    else
      {:error, message} -> abort_startup(message)
    end
  end

  defp launch(_flags, file) do
    log_startup(file)
    open_editor(file)
  end

  @spec log_startup(String.t() | nil) :: :ok
  defp log_startup(nil), do: Minga.Log.debug(:editor, "Starting with empty buffer")
  defp log_startup(file), do: Minga.Log.debug(:editor, "Opening file: #{file}")

  @spec start_headless_gateway(pos_integer(), :inet.ip_address(), String.t() | nil) :: :ok
  defp start_headless_gateway(port, ip, auth_token) do
    case MingaAgent.Runtime.start_gateway(port: port, ip: ip, auth_token: auth_token) do
      {:ok, _pid} ->
        Minga.Log.info(:agent, "Headless Gateway listening on #{:inet.ntoa(ip)}:#{port}")

      {:error, {:already_started, _pid}} ->
        Minga.Log.info(:agent, "Headless Gateway already running on #{:inet.ntoa(ip)}:#{port}")

      {:error, reason} ->
        abort_startup("Failed to start Gateway: #{inspect(reason)}")
    end

    :ok
  end

  @spec maybe_start_distribution(flags()) :: :ok | {:error, String.t()}
  defp maybe_start_distribution(%{headless: true} = flags) do
    case ensure_distribution_started(:server, flags) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Erlang distribution for headless mode: #{reason}"}
    end
  end

  defp maybe_start_distribution(flags) do
    case Minga.Distribution.Config.load() do
      [] -> :ok
      _servers -> ensure_distribution_started(:client, flags)
    end
  end

  @spec ensure_distribution_started(:server | :client, flags()) :: :ok | {:error, String.t()}
  defp ensure_distribution_started(role, flags) do
    name = distribution_node_name(role, flags)
    mode = if flags.short_name, do: :shortnames, else: :longnames

    with {:ok, cookie} <- distribution_cookie(flags) do
      case start_node_if_needed(name, mode) do
        :ok ->
          set_cookie_and_log(cookie, :ok, name)

        {:ok, _pid} = result ->
          set_cookie_and_log(cookie, result, name)

        {:error, reason} = result ->
          log_distribution_result(result, name)
          {:error, inspect(reason)}
      end
    end
  end

  @spec start_node_if_needed(atom(), :shortnames | :longnames) ::
          :ok | {:ok, pid()} | {:error, term()}
  defp start_node_if_needed(name, mode) do
    if Node.alive?(), do: :ok, else: Node.start(name, name_domain: mode)
  end

  @spec distribution_node_name(:server | :client, flags()) :: atom()
  defp distribution_node_name(_role, %{node_name: name}) when is_binary(name) do
    distribution_atom(name)
  end

  defp distribution_node_name(role, flags) do
    prefix = if role == :server, do: "minga_server", else: "minga_client"
    hostname = hostname(flags.short_name)
    distribution_atom("#{prefix}@#{hostname}")
  end

  @spec hostname(boolean()) :: String.t()
  defp hostname(short_name?) do
    {:ok, name} = :inet.gethostname()
    format_hostname(name, short_name?)
  rescue
    error in MatchError ->
      abort_startup("Failed to resolve local hostname: #{inspect(error.term)}")
  end

  @spec format_hostname(charlist(), boolean()) :: String.t()
  defp format_hostname(name, true), do: name |> List.to_string() |> String.split(".") |> hd()
  defp format_hostname(name, false), do: List.to_string(name)

  @doc false
  @spec distribution_cookie(flags()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def distribution_cookie(%{cookie_file: path}) when is_binary(path), do: read_cookie_file(path)
  def distribution_cookie(%{cookie: cookie}) when is_binary(cookie), do: {:ok, cookie}
  def distribution_cookie(_flags), do: {:ok, System.get_env("MINGA_COOKIE")}

  @spec set_cookie_if_present(String.t() | nil) :: :ok | {:error, String.t()}
  defp set_cookie_if_present(nil), do: :ok

  defp set_cookie_if_present(cookie) do
    case Cookie.to_atom(cookie) do
      {:ok, atom} ->
        Node.set_cookie(atom)
        :ok

      {:error, :weak_or_invalid} ->
        {:error,
         "Erlang distribution cookie must be at least 32 bytes and contain only letters, numbers, dot, underscore, at, or hyphen"}
    end
  end

  @spec distribution_atom(String.t()) :: atom()
  defp distribution_atom(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9_.@-]+$/, value) do
      :erlang.binary_to_atom(value, :utf8)
    else
      raise ArgumentError, "invalid Erlang distribution atom: #{inspect(value)}"
    end
  end

  @spec read_cookie_file(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_cookie_file(path) do
    case Cookie.read_file(path) do
      {:ok, cookie} ->
        {:ok, cookie}

      {:error, reason} ->
        {:error, "Failed to read Erlang cookie file #{path}: #{inspect(reason)}"}
    end
  end

  @spec log_distribution_result(:ok | {:ok, pid()} | {:error, term()}, atom()) :: :ok
  defp log_distribution_result(:ok, _name) do
    Minga.Log.debug(:distribution, "Distribution already running as #{Node.self()}")
  end

  defp log_distribution_result({:ok, _pid}, name) do
    Minga.Log.info(:distribution, "Started Erlang distribution node #{name}")
  end

  defp log_distribution_result({:error, reason}, name) do
    Minga.Log.warning(
      :distribution,
      "Failed to start Erlang distribution node #{name}: #{inspect(reason)}"
    )
  end

  @doc false
  @spec gateway_port(flags()) :: {:ok, pos_integer()} | {:error, String.t()}
  def gateway_port(%{gateway_port: port}) when is_integer(port), do: {:ok, port}

  def gateway_port(_flags) do
    case System.get_env("MINGA_GATEWAY_PORT") do
      nil -> {:ok, @default_gateway_port}
      value -> env_gateway_port(value)
    end
  end

  @spec gateway_ip(flags()) :: {:ok, :inet.ip_address()} | {:error, String.t()}
  defp gateway_ip(%{gateway_host: host}) when is_binary(host) do
    case parse_gateway_ip(host) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> {:error, "--host requires a valid IP address"}
    end
  end

  defp gateway_ip(_flags) do
    case System.get_env("MINGA_GATEWAY_HOST") do
      nil -> {:ok, {127, 0, 0, 1}}
      host -> parse_gateway_env_ip(host)
    end
  end

  @spec parse_gateway_ip(String.t()) :: {:ok, :inet.ip_address()} | {:error, :einval}
  defp parse_gateway_ip(host), do: :inet.parse_address(String.to_charlist(host))

  @spec parse_gateway_env_ip(String.t()) :: {:ok, :inet.ip_address()} | {:error, String.t()}
  defp parse_gateway_env_ip(host) do
    case parse_gateway_ip(host) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> {:error, "MINGA_GATEWAY_HOST must be a valid IP address"}
    end
  end

  @spec gateway_auth_token() :: String.t() | nil
  defp gateway_auth_token, do: System.get_env("MINGA_GATEWAY_TOKEN")

  @spec env_gateway_port(String.t()) :: {:ok, pos_integer()} | {:error, String.t()}
  defp env_gateway_port(value) do
    case parse_port(value) do
      {:ok, port} -> {:ok, port}
      :error -> {:error, "MINGA_GATEWAY_PORT must be a TCP port between 1 and 65535"}
    end
  end

  @spec parse_port(String.t()) :: {:ok, pos_integer()} | :error
  defp parse_port(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> :error
    end
  end

  @spec set_cookie_and_log(String.t() | nil, :ok | {:ok, pid()}, atom()) ::
          :ok | {:error, String.t()}
  defp set_cookie_and_log(cookie, result, name) do
    case set_cookie_if_present(cookie) do
      :ok ->
        log_distribution_result(result, name)
        :ok

      {:error, message} ->
        {:error, message}
    end
  end

  @spec abort_startup(String.t()) :: no_return()
  defp abort_startup(message) do
    Minga.Log.error(:editor, message)
    IO.puts(:stderr, message)
    System.stop(1)
    exit({:shutdown, 1})
  end

  @spec store_startup_flags(flags()) :: :ok
  defp store_startup_flags(flags) do
    Application.put_env(:minga, :cli_startup_flags, flags)
    if flags.minimal, do: Application.put_env(:minga, :minimal_mode, true)
    if flags.minimal or flags.force_editor, do: Application.put_env(:minga, :force_editor, true)
    :ok
  end

  @spec usage() :: String.t()
  defp usage do
    """
    minga #{Minga.version()} -- BEAM-powered modal text editor

    Usage: minga [options] [filename]

    Options:
      -h, --help             Show this help message
      -v, --version          Show version
      --config <path>        Use a custom config file instead of the default
      --editor               Start in file editing mode (skip agentic view)
      --minimal              Minimal mode: editor-only, no services/agent (for GIT_EDITOR use)
      --no-context           Don't load the file as agent context
      --headless             Start services and agent runtime without a GUI frontend
      --name <name@host>     Distributed Erlang long node name
      --sname <name>         Distributed Erlang short node name
      --cookie-file <path>   Read distributed Erlang cookie from a 0600 file
      --cookie <cookie>      Distributed Erlang cookie (prefer --cookie-file or MINGA_COOKIE)
      --host <ip>            Gateway bind IP for headless mode (default: 127.0.0.1)
      --port <port>          Gateway port for headless mode (default: 4820)

    Examples:
      minga                              Start agentic view
      minga README.md                    Start agentic view with file as context
      minga --editor README.md           Open file in traditional editor
      MINGA_COOKIE=$(openssl rand -base64 32 | tr -d '/+=') minga --headless   Start detachable agent server
      minga --config ~/minimal.exs       Use a custom config profile
    """
  end

  @spec open_editor(String.t() | nil) :: :ok
  defp open_editor(file_path) do
    case file_path do
      nil ->
        :ok

      path ->
        {interval, retries} = editor_wait_params()

        case wait_for_editor(interval, retries) do
          :ok -> MingaEditor.open_file(path)
          :timeout -> Minga.Log.error(:editor, "Editor process did not start in time")
        end
    end

    :ok
  end

  @spec editor_wait_params() :: {non_neg_integer(), non_neg_integer()}
  defp editor_wait_params do
    # Tests can override the polling interval and retry count; production waits up to one second by default.
    Application.get_env(:minga, :editor_wait_params, {50, 20})
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
end
