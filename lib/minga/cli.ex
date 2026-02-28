defmodule Minga.CLI do
  @moduledoc """
  Command-line interface for Minga.

  Serves as the entry point for both `mix minga <filename>` and
  the standalone Burrito binary (`./minga <filename>`).

  In Burrito mode, arguments are fetched via `Burrito.Util.Args.argv/0`
  which works whether running standalone or under Mix.
  """

  alias Burrito.Util.Args

  require Logger

  @doc "Main entry point for the CLI."
  @spec main([String.t()]) :: :ok
  def main(args) do
    case parse_args(args) do
      {:file, path} ->
        Logger.debug("Opening file: #{path}")
        open_editor(path)

      :no_file ->
        Logger.debug("Starting with empty buffer")
        open_editor(nil)

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

  Returns `{:file, path}`, `:no_file`, or `{:error, message}`.
  """
  @spec parse_args([String.t()]) :: {:file, String.t()} | :no_file | {:error, String.t()}
  def parse_args([]), do: :no_file
  def parse_args(["--help" | _]), do: {:error, usage()}
  def parse_args(["-h" | _]), do: {:error, usage()}
  def parse_args(["--version" | _]), do: {:error, "minga #{Minga.version()}"}
  def parse_args(["-v" | _]), do: {:error, "minga #{Minga.version()}"}
  def parse_args([file_path | _]), do: {:file, file_path}

  @spec usage() :: String.t()
  defp usage do
    """
    minga #{Minga.version()} — BEAM-powered modal text editor

    Usage: minga [filename]

    Options:
      -h, --help       Show this help message
      -v, --version    Show version

    Examples:
      minga README.md    Open a file
      minga              Start with empty buffer
    """
  end

  @spec open_editor(String.t() | nil) :: :ok
  defp open_editor(file_path) do
    case file_path do
      nil ->
        :ok

      path ->
        # Wait for the editor to be ready
        Process.sleep(100)

        case Process.whereis(Minga.Editor) do
          nil ->
            Logger.debug("Editor not running yet")

          _pid ->
            Minga.Editor.open_file(path)
        end
    end

    :ok
  end
end
