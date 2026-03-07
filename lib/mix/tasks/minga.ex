defmodule Mix.Tasks.Minga do
  @shortdoc "Launch the Minga text editor"

  @moduledoc """
  Launches the Minga text editor.

  ## Usage

      mix minga [--gui] [filename]

  ## Options

      --gui    Launch the native macOS GUI instead of the TUI

  ## Examples

      mix minga README.md        # Open a file in TUI
      mix minga --gui README.md  # Open a file in GUI
      mix minga                  # Start with empty buffer
  """

  use Mix.Task

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    {gui?, remaining_args} = extract_gui_flag(args)

    # Enable the editor (Port Manager + Editor GenServer) before app.start
    Application.put_env(:minga, :start_editor, true)

    if gui? do
      Application.put_env(:minga, :backend, :gui)
    end

    # Ensure the application is started
    Mix.Task.run("app.start")
    Minga.CLI.main(remaining_args)

    # Keep the process alive
    unless "--help" in args or "-h" in args do
      receive do
      end
    end

    :ok
  end

  @spec extract_gui_flag([String.t()]) :: {boolean(), [String.t()]}
  defp extract_gui_flag(args) do
    if "--gui" in args do
      {true, List.delete(args, "--gui")}
    else
      {false, args}
    end
  end
end
