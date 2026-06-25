defmodule MingaEditor.UI do
  @moduledoc """
  Visual primitives domain facade.

  Themes, faces, highlighting, icons, and fonts. Shared by all
  presentation surfaces (Shell.Traditional, extension shells, TUI, GUI).

  External callers use this facade for behavior. Struct types
  (`MingaEditor.UI.Theme.t()`, `Minga.Core.Face.t()`) may be referenced
  directly in `@spec` annotations per AGENTS.md type-crossing rules.
  """

  # ── Theme ─────────────────────────────────────────────────────────────────

  @doc "Returns the theme struct for the given name. Raises on unknown theme."
  @spec get_theme!(atom()) :: MingaEditor.UI.Theme.t()
  def get_theme!(name), do: MingaEditor.UI.Theme.get!(name)

  @doc "Returns a list of all available theme names."
  @spec list_themes() :: [atom()]
  def list_themes, do: MingaEditor.UI.Theme.available()

  @doc "Returns the default theme name."
  @spec default_theme() :: atom()
  def default_theme, do: MingaEditor.UI.Theme.default()

  @doc "Registers user-defined themes from a map of `%{name => theme_struct}`."
  @spec register_user_themes(map()) :: :ok | {:error, MingaEditor.UI.Theme.register_error()}
  def register_user_themes(themes), do: MingaEditor.UI.Theme.register_user_themes(themes)

  # ── Devicon ───────────────────────────────────────────────────────────────

  @doc "Returns the icon character and hex color for a filetype."
  @spec icon_and_color(atom()) :: {String.t(), non_neg_integer()}
  def icon_and_color(filetype), do: Minga.Language.Devicon.icon_and_color(filetype)
end
