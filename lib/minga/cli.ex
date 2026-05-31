defmodule Minga.CLI do
  @moduledoc """
  Command-line interface for Minga.

  Serves as the entry point for both `mix minga <filename>` and the standalone Burrito binary (`./minga <filename>`). In Burrito mode, arguments are fetched via `Burrito.Util.Args.argv/0` which works whether running standalone or under Mix.

  ## Startup view

  By default, Minga boots into the agentic view (controlled by the `:startup_view` config option). CLI flags can override the config:

  - `--editor` forces the traditional file editing view
  - File arguments open in the traditional file editing view by default
  - Directory arguments open the agentic view with the directory as context
  - `--no-context` opens the agentic view but skips loading the CLI file argument as preview context
  - `--headless` starts only the services and agent runtime, plus the JSON-RPC Gateway
  """

  alias Burrito.Util.Args
  alias Minga.Distribution.Cookie
  alias Minga.Remote.ControlEndpoint

  @typedoc "Parsed CLI result."
  @type parsed ::
          {:open, file :: String.t() | nil, flags()}
          | {:attach, url :: String.t(), flags()}
          | {:sessions, url :: String.t(), flags()}
          | {:detach, flags()}
          | {:kill_session, url :: String.t(), flags()}
          | {:login, flags()}
          | {:error, String.t()}

  @typedoc "Startup view mode requested by CLI flags."
  @type view_mode :: :auto | :editor | :agentic

  @typedoc "CLI flags that override config options."
  @type flags :: %{
          view_mode: view_mode(),
          no_context: boolean(),
          config_file: String.t() | nil,
          debug_log: String.t() | nil,
          headless: boolean(),
          minimal: boolean(),
          safe_mode: boolean(),
          node_name: String.t() | nil,
          short_name: boolean(),
          cookie: String.t() | nil,
          cookie_file: String.t() | nil,
          gateway_port: pos_integer() | nil,
          gateway_host: String.t() | nil
        }

  @default_flags %{
    view_mode: :auto,
    no_context: false,
    config_file: nil,
    debug_log: nil,
    headless: false,
    minimal: false,
    safe_mode: false,
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
        store_startup_flags(flags, file)

        with :ok <- maybe_start_debug_log(flags),
             :ok <- maybe_start_distribution(flags) do
          launch(flags, file)
        else
          {:error, message} -> abort_startup(message)
        end

      {:attach, url, flags} ->
        store_startup_flags(flags, nil)

        with :ok <- maybe_start_debug_log(flags),
             :ok <- maybe_start_remote_distribution(flags),
             {:ok, _result} <- Minga.Remote.CLI.attach(url) do
          launch(flags, nil)
          finish_remote_attach()
        else
          {:error, message} -> abort_startup(message)
        end

      {:sessions, url, flags} ->
        with :ok <- maybe_start_debug_log(flags),
             :ok <- maybe_start_terminal_distribution(flags),
             :ok <- Minga.Remote.CLI.sessions(url) do
          System.stop(0)
        else
          {:error, message} -> abort_startup(message)
        end

      {:detach, flags} ->
        with :ok <- maybe_start_debug_log(flags),
             :ok <- maybe_start_terminal_distribution(flags),
             :ok <- Minga.Remote.CLI.detach() do
          System.stop(0)
        else
          {:error, message} -> abort_startup(message)
        end

      {:kill_session, url, flags} ->
        with :ok <- maybe_start_debug_log(flags),
             :ok <- maybe_start_terminal_distribution(flags),
             :ok <- Minga.Remote.CLI.kill_session(url) do
          System.stop(0)
        else
          {:error, message} -> abort_startup(message)
        end

      {:login, flags} ->
        with :ok <- maybe_start_debug_log(flags),
             :ok <- MingaAgent.OAuth.ManualCLI.run() do
          System.stop(0)
          :ok
        else
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

  @doc "Returns true when args request minimal mode (for GIT_EDITOR use)."
  @spec minimal_args?([String.t()]) :: boolean()
  def minimal_args?(args) do
    Enum.member?(args, "--minimal")
  end

  @doc "Returns true when args request safe mode."
  @spec safe_args?([String.t()]) :: boolean()
  def safe_args?(args) do
    Enum.member?(args, "--safe") or Enum.member?(args, "-Q")
  end

  @doc "Returns true when args request a terminal-only remote command."
  @spec terminal_command?([String.t()]) :: boolean()
  def terminal_command?(args) do
    args
    |> first_command_token()
    |> terminal_command_token?()
  end

  @doc "Returns true when args request a terminal-only remote command after parsing flags."
  @spec terminal_command_args?([String.t()]) :: boolean()
  def terminal_command_args?(args) do
    terminal_command?(args)
  end

  @spec first_command_token([String.t()]) :: String.t() | nil
  defp first_command_token([]), do: nil

  defp first_command_token([flag, _value | rest])
       when flag in [
              "--config",
              "--debug-log",
              "-D",
              "--name",
              "--sname",
              "--cookie",
              "--cookie-file",
              "--host",
              "--port"
            ],
       do: first_command_token(rest)

  defp first_command_token([flag | rest])
       when flag in ["--editor", "--no-context", "--headless", "--minimal", "--safe", "-Q"],
       do: first_command_token(rest)

  defp first_command_token([token | _rest]), do: token

  @spec terminal_command_token?(String.t() | nil) :: boolean()
  defp terminal_command_token?("sessions"), do: true
  defp terminal_command_token?("detach"), do: true
  defp terminal_command_token?("kill-session"), do: true
  defp terminal_command_token?("login"), do: true
  defp terminal_command_token?(_token), do: false

  @doc """
  Returns the output for info-only flags (`--version`/`-v`, `--help`/`-h`).

  These flags should print and exit without booting the supervision tree,
  so the application start path can short-circuit before doing any work.
  Returns `:none` when the args don't request info-only output.
  """
  @spec info_flag_output([String.t()]) :: {:ok, String.t()} | :none
  def info_flag_output(args) when is_list(args) do
    cond do
      "--version" in args or "-v" in args -> {:ok, "minga #{Minga.version()}"}
      "--help" in args or "-h" in args -> {:ok, usage()}
      true -> :none
    end
  end

  @doc "Returns the startup flags stored by the CLI, or defaults if none were set."
  @spec startup_flags() :: flags()
  def startup_flags do
    stored = Application.get_env(:minga, :cli_startup_flags, %{})
    Map.merge(@default_flags, stored)
  end

  @doc "Returns the project root inferred from the stored startup CLI target, if any."
  @spec startup_project_root() :: String.t() | nil
  def startup_project_root do
    Application.get_env(:minga, :cli_startup_project_root)
  end

  @doc "Returns the project root inferred from the current CLI argv before startup flags are stored."
  @spec argv_startup_project_root() :: String.t() | nil
  def argv_startup_project_root do
    argv_startup_project_root(&Args.argv/0)
  end

  @doc false
  @spec argv_startup_project_root((-> [String.t()])) :: String.t() | nil
  def argv_startup_project_root(fetch_argv) when is_function(fetch_argv, 0) do
    fetch_argv.()
    |> startup_project_root_from_args()
  rescue
    error ->
      log_argv_startup_project_root_failure({error, __STACKTRACE__})
      nil
  catch
    kind, reason ->
      log_argv_startup_project_root_failure({kind, reason})
      nil
  end

  @doc "Returns the marked project root inferred from the current working directory, if any."
  @spec cwd_startup_project_root() :: String.t() | nil
  def cwd_startup_project_root do
    File.cwd!()
    |> cwd_startup_project_root()
  rescue
    error ->
      log_cwd_startup_project_root_failure({error, __STACKTRACE__})
      nil
  catch
    kind, reason ->
      log_cwd_startup_project_root_failure({kind, reason})
      nil
  end

  @doc false
  @spec cwd_startup_project_root(String.t()) :: String.t() | nil
  def cwd_startup_project_root(cwd) when is_binary(cwd) do
    cwd
    |> Path.expand()
    |> detect_marked_project_root_from_dir(Minga.Project.Detector.default_markers())
  end

  @doc "Returns the project root inferred from raw CLI args, if they name a project or file inside a project."
  @spec startup_project_root_from_args([String.t()]) :: String.t() | nil
  def startup_project_root_from_args(args) when is_list(args) do
    case parse_args(args) do
      {:open, file, _flags} -> detect_startup_project_root(file)
      {:error, _message} -> nil
    end
  end

  # ── Argument parsing ────────────────────────────────────────────────────────

  @spec parse_args([String.t()], String.t() | nil, flags()) :: parsed()
  defp parse_args([], file, flags), do: {:open, file, flags}

  defp parse_args(["attach", url | rest], nil, flags) when is_binary(url) do
    parse_remote_subcommand(rest, {:attach, url, flags})
  end

  defp parse_args(["attach" | _rest], _file, _flags) do
    {:error, "attach requires an ssh://host/path URL\n\n#{usage()}"}
  end

  defp parse_args(["sessions", url | rest], nil, flags) when is_binary(url) do
    parse_remote_subcommand(rest, {:sessions, url, flags})
  end

  defp parse_args(["sessions" | _rest], _file, _flags) do
    {:error, "sessions requires an ssh://host URL\n\n#{usage()}"}
  end

  defp parse_args(["detach" | rest], nil, flags) do
    parse_remote_subcommand(rest, {:detach, flags})
  end

  defp parse_args(["kill-session", url | rest], nil, flags) when is_binary(url) do
    parse_remote_subcommand(rest, {:kill_session, url, flags})
  end

  defp parse_args(["kill-session" | _rest], _file, _flags) do
    {:error, "kill-session requires an ssh://host/path URL\n\n#{usage()}"}
  end

  defp parse_args(["login", "--manual" | rest], nil, flags) do
    parse_remote_subcommand(rest, {:login, flags})
  end

  defp parse_args(["login" | _rest], _file, _flags) do
    {:error, "login currently requires --manual outside the editor\n\n#{usage()}"}
  end

  defp parse_args(["--help" | _], _file, _flags), do: {:error, usage()}
  defp parse_args(["-h" | _], _file, _flags), do: {:error, usage()}
  defp parse_args(["--version" | _], _file, _flags), do: {:error, "minga #{Minga.version()}"}
  defp parse_args(["-v" | _], _file, _flags), do: {:error, "minga #{Minga.version()}"}

  defp parse_args(["--editor" | rest], file, flags) do
    parse_args(rest, file, %{flags | view_mode: :editor})
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

  defp parse_args(["--debug-log", <<"--", _::binary>> | _], _file, _flags) do
    {:error, "--debug-log requires a path argument, not a flag\n\n#{usage()}"}
  end

  defp parse_args(["--debug-log", "" | _], _file, _flags) do
    {:error, "--debug-log requires a non-empty path argument\n\n#{usage()}"}
  end

  defp parse_args(["--debug-log", path | rest], file, flags) when is_binary(path) do
    parse_args(rest, file, %{flags | debug_log: Path.expand(path)})
  end

  defp parse_args(["--debug-log"], _file, _flags) do
    {:error, "--debug-log requires a path argument\n\n#{usage()}"}
  end

  defp parse_args(["-D", <<"--", _::binary>> | _], _file, _flags) do
    {:error, "-D requires a path argument, not a flag\n\n#{usage()}"}
  end

  defp parse_args(["-D", "" | _], _file, _flags) do
    {:error, "-D requires a non-empty path argument\n\n#{usage()}"}
  end

  defp parse_args(["-D", path | rest], file, flags) when is_binary(path) do
    parse_args(rest, file, %{flags | debug_log: Path.expand(path)})
  end

  defp parse_args(["-D"], _file, _flags) do
    {:error, "-D requires a path argument\n\n#{usage()}"}
  end

  defp parse_args(["--minimal" | rest], file, flags) do
    parse_args(rest, file, %{flags | minimal: true})
  end

  defp parse_args(["--safe" | rest], file, flags) do
    parse_args(rest, file, %{flags | safe_mode: true})
  end

  defp parse_args(["-Q" | rest], file, flags) do
    parse_args(rest, file, %{flags | safe_mode: true})
  end

  defp parse_args([<<"--", _::binary>> = flag | _], _file, _flags) do
    {:error, "unknown flag: #{flag}\n\n#{usage()}"}
  end

  defp parse_args([file_path | rest], _file, flags) do
    parse_args(rest, file_path, flags)
  end

  @spec parse_remote_subcommand([String.t()], parsed()) :: parsed()
  defp parse_remote_subcommand([], action), do: action

  defp parse_remote_subcommand([flag | _rest], _action),
    do: {:error, "unexpected argument for remote subcommand: #{flag}\n\n#{usage()}"}

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

  defp launch(%{headless: false}, file) do
    case publish_local_control_endpoint() do
      :ok ->
        log_startup(file)
        open_startup_target(file)

      {:error, message} ->
        abort_startup(message)
    end
  end

  @spec log_startup(String.t() | nil) :: :ok
  defp log_startup(nil), do: Minga.Log.debug(:editor, "Starting with empty buffer")

  defp log_startup(path) do
    if File.dir?(path) do
      Minga.Log.debug(:editor, "Opening project: #{path}")
    else
      Minga.Log.debug(:editor, "Opening file: #{path}")
    end
  end

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

  @spec maybe_start_debug_log(flags()) :: :ok | {:error, String.t()}
  defp maybe_start_debug_log(%{debug_log: nil}), do: :ok

  defp maybe_start_debug_log(%{debug_log: path}) when is_binary(path) do
    case Minga.DebugLog.start(path) do
      {:ok, _pid} ->
        :ok

      {:error, {:debug_log_unwritable, ^path, reason}} ->
        {:error, debug_log_error(path, reason)}

      {:error, {:debug_log_init_failed, ^path, reason}} ->
        {:error, debug_log_init_error(path, reason)}

      {:error, {:debug_log_init_failed, ^path, reason, {:close_failed, close_reason}}} ->
        {:error, debug_log_init_error(path, reason, close_reason)}

      {:error, {:debug_log_already_started, existing_path, ^path}} ->
        {:error, "Debug log is already writing to #{existing_path}, not #{path}"}

      {:error, reason} ->
        {:error, "Failed to start debug log #{path}: #{inspect(reason)}"}
    end
  end

  @spec debug_log_error(String.t(), term()) :: String.t()
  defp debug_log_error(path, reason) do
    "Debug log path is not writable: #{path} (#{inspect(reason)})"
  end

  @spec debug_log_init_error(String.t(), term(), term() | nil) :: String.t()
  defp debug_log_init_error(path, reason, close_reason \\ nil) do
    message = "Debug log could not initialize at #{path}: #{inspect(reason)}"

    if close_reason == nil do
      message
    else
      "#{message} (cleanup failed: #{inspect(close_reason)})"
    end
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

  @spec maybe_start_remote_distribution(flags()) :: :ok | {:error, String.t()}
  defp maybe_start_remote_distribution(flags) do
    case ensure_distribution_started(:client, flags) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Erlang distribution for remote attach: #{reason}"}
    end
  end

  @spec maybe_start_terminal_distribution(flags()) :: :ok | {:error, String.t()}
  defp maybe_start_terminal_distribution(flags) do
    case ensure_distribution_started(:control, flags) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Erlang distribution for terminal command: #{reason}"}
    end
  end

  @spec ensure_distribution_started(:server | :client | :control, flags()) ::
          :ok | {:error, String.t()}
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

  @spec distribution_node_name(:server | :client | :control, flags()) :: atom()
  defp distribution_node_name(_role, %{node_name: name}) when is_binary(name) do
    distribution_atom(name)
  end

  defp distribution_node_name(role, flags) do
    prefix =
      case role do
        :server -> "minga_server"
        :client -> "minga_client"
        :control -> "minga_control"
      end

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

  @spec publish_local_control_endpoint() :: :ok | {:error, String.t()}
  defp publish_local_control_endpoint do
    case ControlEndpoint.publish_current_node() do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Failed to publish local control endpoint: #{inspect(reason)}"}
    end
  end

  @spec finish_remote_attach() :: :ok | no_return()
  defp finish_remote_attach do
    case Minga.Remote.CLI.connect_pending_editor_attach() do
      :ok -> :ok
      :none -> :ok
      {:error, message} -> abort_startup(message)
    end
  end

  @spec abort_startup(String.t()) :: no_return()
  defp abort_startup(message) do
    Minga.Log.error(:editor, message)
    Logger.flush()
    flush_debug_log()
    IO.puts(:stderr, message)
    System.stop(1)
    exit({:shutdown, 1})
  end

  @spec flush_debug_log() :: :ok
  defp flush_debug_log do
    case Minga.DebugLog.stop() do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Failed to stop debug log before shutdown: #{inspect(reason)}")
    end
  end

  @doc "Applies flag implications to a flags map."
  @spec apply_flag_implications(flags()) :: flags()
  def apply_flag_implications(flags), do: apply_flag_implications(flags, nil)

  @doc "Applies flag implications with file-aware startup view resolution."
  @spec apply_flag_implications(flags(), String.t() | nil) :: flags()
  def apply_flag_implications(%{minimal: true} = flags, _file) do
    %{flags | view_mode: :editor}
  end

  def apply_flag_implications(%{view_mode: :editor} = flags, _file), do: flags
  def apply_flag_implications(%{view_mode: :agentic} = flags, _file), do: flags

  def apply_flag_implications(%{view_mode: :auto, no_context: true} = flags, _file),
    do: %{flags | view_mode: :agentic}

  def apply_flag_implications(%{view_mode: :auto} = flags, nil), do: flags

  def apply_flag_implications(%{view_mode: :auto} = flags, file),
    do: resolve_auto_view_mode(flags, file)

  @spec resolve_auto_view_mode(flags(), String.t()) :: flags()
  defp resolve_auto_view_mode(flags, file) do
    resolve_auto_view_mode_for_directory(flags, File.dir?(file))
  end

  @spec resolve_auto_view_mode_for_directory(flags(), boolean()) :: flags()
  defp resolve_auto_view_mode_for_directory(flags, true), do: %{flags | view_mode: :agentic}
  defp resolve_auto_view_mode_for_directory(flags, false), do: %{flags | view_mode: :editor}

  @spec store_startup_flags(flags(), String.t() | nil) :: :ok
  defp store_startup_flags(flags, file) do
    effective = apply_flag_implications(flags, file)
    Application.put_env(:minga, :cli_startup_flags, effective)
    store_startup_project_root(file)
    store_debug_log_path(effective.debug_log)
    Minga.SafeMode.put(effective.safe_mode)
    if effective.minimal, do: Application.put_env(:minga, :minimal_mode, true)
    :ok
  end

  @spec store_startup_project_root(String.t() | nil) :: :ok
  defp store_startup_project_root(nil) do
    case cwd_startup_project_root() do
      root when is_binary(root) -> Application.put_env(:minga, :cli_startup_project_root, root)
      nil -> Application.delete_env(:minga, :cli_startup_project_root)
    end

    :ok
  end

  defp store_startup_project_root(path) when is_binary(path) do
    case detect_startup_project_root(path) do
      root when is_binary(root) -> Application.put_env(:minga, :cli_startup_project_root, root)
      nil -> Application.delete_env(:minga, :cli_startup_project_root)
    end

    :ok
  end

  @spec detect_startup_project_root(String.t() | nil) :: String.t() | nil
  defp detect_startup_project_root(nil), do: nil

  defp detect_startup_project_root(path) do
    path
    |> Path.expand()
    |> detect_expanded_startup_project_root()
  end

  @spec detect_expanded_startup_project_root(String.t()) :: String.t() | nil
  defp detect_expanded_startup_project_root(path) do
    if File.dir?(path) do
      detect_directory_project_root(path)
    else
      detect_file_project_root(path)
    end
  end

  @spec detect_directory_project_root(String.t()) :: String.t()
  defp detect_directory_project_root(path) do
    case detect_marked_project_root_from_dir(path, Minga.Project.Detector.default_markers()) do
      root when is_binary(root) -> root
      nil -> path
    end
  end

  @spec detect_marked_project_root_from_dir(String.t(), [{String.t(), atom()}]) ::
          String.t() | nil
  defp detect_marked_project_root_from_dir(dir, markers) do
    case directory_marker_type(dir, markers) do
      {:ok, _type} -> dir
      :none -> detect_marked_project_root_from_parent(dir, markers)
    end
  end

  @spec detect_marked_project_root_from_parent(String.t(), [{String.t(), atom()}]) ::
          String.t() | nil
  defp detect_marked_project_root_from_parent(dir, markers) do
    parent = Path.dirname(dir)

    if parent == dir do
      nil
    else
      detect_marked_project_root_from_dir(parent, markers)
    end
  end

  @spec directory_marker_type(String.t(), [{String.t(), atom()}]) :: {:ok, atom()} | :none
  defp directory_marker_type(dir, markers) do
    Enum.find_value(markers, :none, fn {marker, type} ->
      if File.exists?(Path.join(dir, marker)), do: {:ok, type}, else: nil
    end)
  end

  @spec detect_file_project_root(String.t()) :: String.t() | nil
  defp detect_file_project_root(path) do
    case Minga.Project.Detector.detect(path) do
      {:ok, root, _type} -> root
      :none -> nil
    end
  end

  @spec log_argv_startup_project_root_failure(term()) :: :ok
  defp log_argv_startup_project_root_failure(reason) do
    Minga.Log.warning(
      :editor,
      "Could not infer startup project root from argv: #{inspect(reason)}"
    )
  end

  @spec log_cwd_startup_project_root_failure(term()) :: :ok
  defp log_cwd_startup_project_root_failure(reason) do
    Minga.Log.warning(
      :editor,
      "Could not infer startup project root from cwd: #{inspect(reason)}"
    )
  end

  @spec store_debug_log_path(String.t() | nil) :: :ok
  defp store_debug_log_path(nil) do
    Application.delete_env(:minga, :debug_log_path)
    :ok
  end

  defp store_debug_log_path(path) when is_binary(path) do
    Application.put_env(:minga, :debug_log_path, path)
    :ok
  end

  @spec usage() :: String.t()
  defp usage do
    """
    minga #{Minga.version()} -- BEAM-powered modal text editor

    Usage: minga [options] [filename]
           minga attach ssh://[user@]host[:port]/path
           minga sessions ssh://[user@]host[:port]
           minga detach
           minga kill-session ssh://[user@]host[:port]/path
           minga login --manual

    Options:
      -h, --help             Show this help message
      -v, --version          Show version
      --config <path>        Use a custom config file instead of the default
      -D, --debug-log <path> Append *Messages* and *Warnings* entries to a crash-safe log
      --editor               Start in file editing mode (skip agentic view)
      --minimal              Minimal mode: editor-only, no services/agent (for GIT_EDITOR use)
      -Q, --safe             Safe mode: skip user config, user modules, after hooks, and extensions
      --no-context           Keep agentic view and don't load the file as agent context
      --headless             Start services and agent runtime without a GUI frontend
      --name <name@host>     Distributed Erlang long node name
      --sname <name>         Distributed Erlang short node name
      --cookie-file <path>   Read distributed Erlang cookie from a 0600 file
      --cookie <cookie>      Distributed Erlang cookie (prefer --cookie-file or MINGA_COOKIE)
      --host <ip>            Gateway bind IP for headless mode (default: 127.0.0.1)
      --port <port>          Gateway port for headless mode (default: 4820)

    Examples:
      minga                              Start agentic view
      minga README.md                    Open file for editing
      minga .                            Start agentic view with project as context
      minga --editor README.md           Open file in traditional editor
      minga attach ssh://devbox/work/app  Attach to a remote server-side checkout
      minga sessions ssh://devbox         List remote sessions without launching the editor
      minga kill-session ssh://devbox/work/app  Stop the remote session for that checkout
      minga login --manual             Sign in on a headless server by pasting the browser redirect
      MINGA_COOKIE=$(openssl rand -base64 32 | tr -d '/+=') minga --headless   Start detachable agent server
      minga --config ~/minimal.exs       Use a custom config profile
      minga --safe                       Start with defaults and no user config
      minga -D /tmp/minga-debug.log      Persist messages and warnings for crash forensics
    """
  end

  @spec open_startup_target(String.t() | nil) :: :ok
  defp open_startup_target(nil), do: :ok

  defp open_startup_target(path) do
    if File.dir?(path) do
      open_project(path)
    else
      open_file(path)
    end
  end

  @spec open_project(String.t()) :: :ok
  defp open_project(path) do
    Minga.Project.switch(path)
    :ok
  end

  @spec open_file(String.t()) :: :ok
  defp open_file(path) do
    {interval, retries} = editor_wait_params()

    case wait_for_editor(interval, retries) do
      :ok -> MingaEditor.open_file(path)
      :timeout -> Minga.Log.error(:editor, "Editor process did not start in time")
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
