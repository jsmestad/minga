defmodule Minga.Application do
  @moduledoc """
  The Minga OTP Application.

  Starts the supervision tree (the "Stamm") that manages all editor
  processes. Uses `rest_for_one` strategy: if the Port Manager crashes,
  the Editor restarts too (since it depends on the renderer).
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    children = [
      # Children will be added in subsequent commits:
      # - Minga.Buffer.Supervisor (DynamicSupervisor)
      # - Minga.Port.Manager
      # - Minga.Editor
    ]

    opts = [strategy: :rest_for_one, name: Minga.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
