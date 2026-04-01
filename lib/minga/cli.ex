defmodule Minga.CLI do
  @moduledoc """
  Command-line interface for Minga.

  Serves as the entry point for both `mix minga <filename>` and
  the standalone Burrito binary (`./minga <filename>`).

  In Burrito mode, arguments are fetched via `Burrito.Util.Args.argv/0`
  which works whether running standalone or under Mix.

  ## Startup view

  By default, Minga boots into the agentic view (controlled by the
  `:startup_view` config option). CLI flags can override the config:

  - `--editor` forces the traditional file editing view
  - `--no-context` opens the agentic view but skips loading the CLI
    file argument as preview context
  """

  alias Burrito.Util.Args

  @typedoc "Parsed CLI result."
  @type parsed ::
          {:open, file :: String.t() | nil, flags()}
          | {:error, String.t()}

  @typedoc "CLI flags that override config options."
  @type flags :: %{
          force_editor: boolean(),
          no_context: boolean(),
          config_file: String.t() | nil
        }

  @default_flags %{force_editor: false, no_context: false, config_file: nil}

  @doc "Main entry point for the CLI."
  @spec main([String.t()]) :: :ok
  def main(args) do
    case parse_args(args) do
      {:open, file, flags} ->
        store_startup_flags(flags)

        if file do
          Minga.Log.debug(:editor, "Opening file: #{file}")
        else
          Minga.Log.debug(:editor, "Starting with empty buffer")
        end

        open_editor(file)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.stop(1)
    end

    :ok
  end

  @doc """
  Entry point used by the OTP application in release/Burrito mode.

  Called from `Minga.Application` when CLI args are detected.
  """
  @spec start_from_cli() :: :ok
  def start_from_cli do
    args = Args.argv()
    main(args)
  end

  @doc """
  Parses CLI arguments into an action.

  Returns `{:open, file_or_nil, flags}` or `{:error, message}`.
  Flags carry CLI overrides for startup behavior.
  """
  @spec parse_args([String.t()]) :: parsed()
  def parse_args(args) do
    parse_args(args, nil, @default_flags)
  end

  @doc """
  Returns the startup flags stored by the CLI, or defaults if none were set.

  The editor reads these once during initialization to decide whether to
  activate the agentic view and whether to auto-load file context.
  """
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

  defp parse_args([<<"--", _::binary>> = flag | _], _file, _flags) do
    {:error, "unknown flag: #{flag}\n\n#{usage()}"}
  end

  defp parse_args([file_path | rest], _file, flags) do
    parse_args(rest, file_path, flags)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec store_startup_flags(flags()) :: :ok
  defp store_startup_flags(flags) do
    Application.put_env(:minga, :cli_startup_flags, flags)
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
      --no-context           Don't load the file as agent context

    Examples:
      minga                          Start agentic view
      minga README.md                Start agentic view with file as context
      minga --editor README.md       Open file in traditional editor
      minga --no-context foo.ex      Agentic view, file open but not as context
      minga --config ~/minimal.exs   Use a custom config profile
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
          :ok ->
            MingaEditor.open_file(path)

          :timeout ->
            Minga.Log.error(:editor, "Editor process did not start in time")
        end
    end

    :ok
  end

  # Returns {interval_ms, max_retries} for editor wait polling.
  # Configurable via application env for tests (default: 50ms × 20 = 1s).
  @spec editor_wait_params() :: {non_neg_integer(), non_neg_integer()}
  defp editor_wait_params do
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
