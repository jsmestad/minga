defmodule ChangesetFs.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: ChangesetFs.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ChangesetFs.AppSupervisor)
  end
end
