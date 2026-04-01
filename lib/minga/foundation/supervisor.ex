defmodule Minga.Foundation.Supervisor do
  @moduledoc """
  Supervises foundational infrastructure that the rest of the application depends on.

  Uses `rest_for_one` because Events (an Elixir Registry) is the pub/sub
  bus for the entire application. If Events crashes under `one_for_one`,
  every subscriber silently loses its registration with no error and no
  crash. `rest_for_one` ensures all children after Events re-initialize
  and re-subscribe.

  ## Children

      Foundation.Supervisor (rest_for_one)
      ├── Minga.Language.Registry      ETS, language definitions
      ├── Minga.Events                 Registry(:duplicate), pub/sub bus
      ├── Minga.Config.Options         GenServer, typed options
      ├── Minga.Keymap.Active          Active keymap state
      ├── Minga.Config.Hooks           Lifecycle hooks
      ├── Minga.Config.Advice          Before/after command advice (ETS)
      ├── MingaAgent.Tool.Registry     Agent tool specs (ETS)
      └── Minga.Language.Filetype.Registry      Filetype detection

  Language.Registry is first because it has no dependencies and nothing
  depends on it within this group. Events is second so that everything
  after it re-subscribes on Events restart.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(_opts) do
    children = [
      Minga.Language.Registry,
      Minga.Events,
      Minga.Config.Options,
      Minga.Keymap.Active,
      Minga.Config.Hooks,
      Minga.Config.Advice,
      MingaAgent.Tool.Registry,
      Minga.Language.Filetype.Registry
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
