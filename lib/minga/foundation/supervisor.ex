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
      ├── MingaAgent.ToolPacks.LSP       Bundled LSP agent tools
      └── Minga.Language.Filetype.Registry Filetype detection

  Language.Registry is first because it owns the ETS table. Bundled packs (language, theme, recipe) start next so consumers see the default catalogs before services, LSP, syntax highlighting, or filetype detection query them. Recipe.Registry precedes RecipePacks and Tool.Registry precedes ToolPacks so the ETS tables exist before packs register into them. Events follows so everything after it re-subscribes on Events restart.
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
    Minga.Telemetry.StartupTimer.mark(:foundation_init)
    alias Minga.Telemetry.StartupTimer

    children = [
      StartupTimer.timed_child_spec(:fnd_lang_registry, Minga.Language.Registry),
      StartupTimer.timed_child_spec(:fnd_lang_packs, Minga.Extensions.LanguagePacks),
      StartupTimer.timed_child_spec(:fnd_theme_packs, Minga.Extensions.ThemePacks),
      StartupTimer.timed_child_spec(:fnd_recipe_registry, Minga.Tool.Recipe.Registry),
      StartupTimer.timed_child_spec(:fnd_recipe_packs, Minga.Extensions.RecipePacks),
      StartupTimer.timed_child_spec(:fnd_events, Minga.Events),
      StartupTimer.timed_child_spec(:fnd_config_options, Minga.Config.Options),
      StartupTimer.timed_child_spec(:fnd_keymap, Minga.Keymap.Active),
      StartupTimer.timed_child_spec(:fnd_hooks, Minga.Config.Hooks),
      StartupTimer.timed_child_spec(:fnd_advice, Minga.Config.Advice),
      StartupTimer.timed_child_spec(:fnd_modeline, Minga.Config.ModelineSegments),
      StartupTimer.timed_child_spec(:fnd_overlay, Minga.Extension.Overlay),
      StartupTimer.timed_child_spec(:fnd_panel, Minga.Extension.Panel),
      StartupTimer.timed_child_spec(:fnd_badge, Minga.Extension.Badge),
      StartupTimer.timed_child_spec(:fnd_tool_registry, MingaAgent.Tool.Registry),
      StartupTimer.timed_child_spec(:fnd_tool_packs_ro, MingaAgent.ToolPacks.ReadOnly),
      StartupTimer.timed_child_spec(:fnd_tool_packs_lsp, MingaAgent.ToolPacks.LSP),
      StartupTimer.timed_child_spec(:fnd_filetype, Minga.Language.Filetype.Registry)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
