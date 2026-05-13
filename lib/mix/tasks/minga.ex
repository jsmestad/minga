defmodule Mix.Tasks.Minga do
  @shortdoc "Launch the Minga text editor"

  @moduledoc """
  Launches Minga.

  ## Usage

      mix minga [filename]
      mix minga +gui [filename]
      mix minga --headless

  ## Options

      +gui        Launch the native macOS GUI instead of the TUI
      --headless  Launch services, agent runtime, and Gateway without an editor frontend

  The `+gui` flag uses a `+` prefix to avoid conflicts with Mix's built-in option parser.
  """

  use Mix.Task

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    {gui?, remaining_args} = extract_gui_flag(args)
    headless? = Minga.CLI.headless_args?(remaining_args)

    unless headless? do
      Application.put_env(:minga, :start_editor, true)
    end

    if gui? and not headless? do
      Application.put_env(:minga, :backend, :gui)
    end

    Mix.Task.run("app.start")
    Minga.CLI.main(remaining_args)

    unless help_args?(args) do
      receive do
      end
    end

    :ok
  end

  @spec extract_gui_flag([String.t()]) :: {boolean(), [String.t()]}
  defp extract_gui_flag(args) do
    if "+gui" in args do
      {true, List.delete(args, "+gui")}
    else
      {false, args}
    end
  end

  @spec help_args?([String.t()]) :: boolean()
  defp help_args?(args) do
    "--help" in args or "-h" in args
  end
end
