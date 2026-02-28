defmodule Minga.Application do
  @moduledoc """
  The Minga OTP Application.

  Starts the supervision tree (the "Stamm") that manages all editor
  processes. Uses `rest_for_one` strategy: if the Port Manager crashes,
  the Editor restarts too (since it depends on the renderer).

  ## Supervision Tree

      Minga.Supervisor (rest_for_one)
      ├── Minga.Buffer.Supervisor (DynamicSupervisor)
      ├── Minga.Port.Manager
      └── Minga.Editor (added in a later commit)
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: Minga.Buffer.Supervisor, strategy: :one_for_one}
      # Minga.Port.Manager and Minga.Editor will be added when
      # they're ready to be wired together (commits 6-8)
    ]

    opts = [strategy: :rest_for_one, name: Minga.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
