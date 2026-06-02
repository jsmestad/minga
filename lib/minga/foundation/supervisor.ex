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
      ├── Minga.Language.Registry        ETS, language definitions
      ├── Minga.Extensions.LanguagePacks Bundled language catalog loader
      ├── Minga.Extensions.ThemePacks    Bundled theme pack loader
      ├── Minga.Tool.Recipe.Registry     ETS, tool install recipes
      ├── Minga.Extensions.RecipePacks   Bundled recipe pack loader
      ├── Minga.Events                   Registry(:duplicate), pub/sub bus
      ├── Minga.Config.Options           GenServer, typed options
      ├── Minga.Keymap.Active            Active keymap state
      ├── Minga.Config.Hooks             Lifecycle hooks
      ├── Minga.Config.Advice            Before/after command advice (ETS)
      ├── Minga.Config.ModelineSegments  Custom modeline segments (ETS)
      ├── Minga.Extension.Overlay        Extension overlay registry (ETS)
      ├── Minga.Extension.Panel          Extension panel registry (ETS)
      ├── Minga.Extension.Badge          Extension badge registry (ETS)
      ├── MingaAgent.Tool.Registry       Agent tool specs (ETS)
      ├── MingaAgent.ToolPacks.ReadOnly  Bundled read-only agent tools
      └── Minga.Language.Filetype.Registry Filetype detection

  Language.Registry is first because it owns the ETS table. Bundled packs (language, theme, recipe) start next so consumers see the default catalogs before services, LSP, syntax highlighting, or filetype detection query them. Recipe.Registry precedes RecipePacks and Tool.Registry precedes ToolPacks.ReadOnly so the ETS tables exist before packs register into them. Events follows so everything after it re-subscribes on Events restart.
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
      Minga.Extensions.LanguagePacks,
      Minga.Extensions.ThemePacks,
      Minga.Tool.Recipe.Registry,
      Minga.Extensions.RecipePacks,
      Minga.Events,
      Minga.Config.Options,
      Minga.Keymap.Active,
      Minga.Config.Hooks,
      Minga.Config.Advice,
      Minga.Config.ModelineSegments,
      Minga.Extension.Overlay,
      Minga.Extension.Panel,
      Minga.Extension.Badge,
      MingaAgent.Tool.Registry,
      MingaAgent.ToolPacks.ReadOnly,
      Minga.Language.Filetype.Registry
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
