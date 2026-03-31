defmodule MingaEditor.UI do
  @moduledoc """
  Visual primitives domain facade.

  Themes, faces, highlighting, icons, and fonts. Shared by all
  presentation surfaces (Shell.Traditional, Shell.Board, TUI, GUI).

  External callers use this facade for behavior. Struct types
  (`MingaEditor.UI.Theme.t()`, `Minga.Core.Face.t()`) may be referenced
  directly in `@spec` annotations per AGENTS.md type-crossing rules.
  """

  # ── Theme ─────────────────────────────────────────────────────────────────

  @doc "Returns the theme struct for the given name. Raises on unknown theme."
  @spec get_theme!(atom()) :: MingaEditor.UI.Theme.t()
  defdelegate get_theme!(name), to: MingaEditor.UI.Theme, as: :get!

  @doc "Returns a list of all available theme names."
  @spec list_themes() :: [atom()]
  defdelegate list_themes, to: MingaEditor.UI.Theme, as: :available

  @doc "Returns the default theme name."
  @spec default_theme() :: atom()
  defdelegate default_theme, to: MingaEditor.UI.Theme, as: :default

  @doc "Registers user-defined themes from a map of `%{name => theme_struct}`."
  @spec register_user_themes(map()) :: :ok
  defdelegate register_user_themes(themes), to: MingaEditor.UI.Theme

  # ── Devicon ───────────────────────────────────────────────────────────────

  @doc "Returns the icon character and hex color for a filetype."
  @spec icon_and_color(atom()) :: {String.t(), non_neg_integer()}
  defdelegate icon_and_color(filetype), to: MingaEditor.UI.Devicon
end
