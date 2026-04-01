defmodule Minga.Runtime do
  @moduledoc """
  Boots the Minga runtime without any frontend or editor.

  This is the headless entry point. Foundation (Layer 0), Services (Layer 1),
  and Agent are fully functional. No rendering, no input handling, no Port.

  ## Supervision Tree

      Minga.Runtime.Headless (rest_for_one)
      ├── Minga.Foundation.Supervisor
      ├── Minga.Buffer.Registry
      ├── Minga.Buffer.Supervisor
      ├── Minga.Services.Supervisor
      └── MingaAgent.Supervisor

  Use `start/1` to boot the headless runtime in tests or standalone scripts
  that need agent capabilities without an editor UI.
  """

  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(_opts \\ []) do
    children = [
      Minga.Foundation.Supervisor,
      {Registry, keys: :unique, name: Minga.Buffer.Registry},
      {DynamicSupervisor, name: Minga.Buffer.Supervisor, strategy: :one_for_one},
      Minga.Services.Supervisor,
      MingaAgent.Supervisor
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Minga.Runtime.Headless)
  end
end
