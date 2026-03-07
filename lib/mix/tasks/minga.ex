defmodule Mix.Tasks.Minga do
  @shortdoc "Launch the Minga text editor"

  @moduledoc """
  Launches the Minga text editor.

  ## Usage

      mix minga [filename]

  ## Examples

      mix minga README.md    # Open a file
      mix minga              # Start with empty buffer
  """

  use Mix.Task

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    # Enable the editor (Port Manager + Editor GenServer) before app.start
    Application.put_env(:minga, :start_editor, true)

    # Ensure the application is started
    Mix.Task.run("app.start")
    Minga.CLI.main(args)

    # Keep the process alive
    unless "--help" in args or "-h" in args do
      receive do
      end
    end

    :ok
  end
end
