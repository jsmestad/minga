defmodule Minga.Application do
  @moduledoc """
  The Minga OTP Application.

  Starts the supervision tree (the "Stamm") that manages all editor
  processes. Uses `rest_for_one` strategy: if the Port Manager crashes,
  the Editor restarts too (since it depends on the renderer).

  ## Supervision Tree

      Minga.Supervisor (rest_for_one)
      ├── Minga.Config.Options
      ├── Minga.Keymap.Store
      ├── Minga.Config.Hooks
      ├── Minga.Config.Loader
      ├── Minga.Buffer.Supervisor (DynamicSupervisor)
      ├── Minga.Port.Manager
      └── Minga.Editor

  In standalone (Burrito) mode, automatically processes CLI arguments
  after the supervision tree is up.
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    base_children = [
      Minga.Config.Options,
      Minga.Keymap.Store,
      Minga.Config.Hooks,
      Minga.Config.Loader,
      Minga.Filetype.Registry,
      {DynamicSupervisor, name: Minga.Buffer.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Minga.Eval.TaskSupervisor},
      Minga.Command.Registry,
      Minga.Diagnostics,
      Minga.LSP.Supervisor
    ]

    editor_children =
      if Application.get_env(:minga, :start_editor, false) or
           Burrito.Util.running_standalone?() do
        backend = Application.get_env(:minga, :backend, :tui)
        [Minga.FileWatcher, {Minga.Port.Manager, [backend: backend]}, Minga.Editor]
      else
        []
      end

    children = base_children ++ editor_children

    opts = [strategy: :rest_for_one, name: Minga.Supervisor]
    result = Supervisor.start_link(children, opts)

    # In Burrito standalone mode, kick off the CLI
    if Burrito.Util.running_standalone?() do
      Task.start(fn -> Minga.CLI.start_from_cli() end)
    end

    result
  end
end
