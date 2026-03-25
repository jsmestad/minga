defmodule Minga.UI do
  @moduledoc """
  Visual primitives domain facade.

  Themes, faces, highlighting, icons, and fonts. Shared by all
  presentation surfaces (Shell.Traditional, Shell.Board, TUI, GUI).

  External callers use this facade for behavior. Struct types
  (`Minga.UI.Theme.t()`, `Minga.UI.Face.t()`) may be referenced
  directly in `@spec` annotations per AGENTS.md type-crossing rules.
  """

  # ── Theme ─────────────────────────────────────────────────────────────────

  @doc "Returns the theme struct for the given name. Raises on unknown theme."
  @spec get_theme!(atom()) :: Minga.UI.Theme.t()
  defdelegate get_theme!(name), to: Minga.UI.Theme, as: :get!

  @doc "Returns a list of all available theme names."
  @spec list_themes() :: [atom()]
  defdelegate list_themes, to: Minga.UI.Theme, as: :available

  # ── Devicon ───────────────────────────────────────────────────────────────

  @doc "Returns the icon character and hex color for a filetype."
  @spec icon_and_color(atom()) :: {String.t(), non_neg_integer()}
  defdelegate icon_and_color(filetype), to: Minga.UI.Devicon

  # ── Face ──────────────────────────────────────────────────────────────────

  @doc "Creates a new face with the given options."
  @spec new_face(keyword()) :: Minga.UI.Face.t()
  defdelegate new_face(opts), to: Minga.UI.Face, as: :new

  # ── Highlight ──────────────────────────────────────────────────────────────

  @doc "Creates a new empty highlight state."
  @spec new_highlight() :: Minga.UI.Highlight.t()
  defdelegate new_highlight, to: Minga.UI.Highlight, as: :new

  @doc "Creates a highlight state from a theme."
  @spec highlight_from_theme(Minga.UI.Theme.t()) :: Minga.UI.Highlight.t()
  defdelegate highlight_from_theme(theme), to: Minga.UI.Highlight, as: :from_theme

  # ── Face Registry ─────────────────────────────────────────────────────────

  @doc "Creates a face registry from a theme."
  @spec face_registry_from_theme(Minga.UI.Theme.t()) :: Minga.UI.Face.Registry.t()
  defdelegate face_registry_from_theme(theme), to: Minga.UI.Face.Registry, as: :from_theme

  @doc "Creates a face registry from a syntax theme map."
  @spec face_registry_from_syntax(map()) :: Minga.UI.Face.Registry.t()
  defdelegate face_registry_from_syntax(syntax), to: Minga.UI.Face.Registry, as: :from_syntax

  # ── Font Registry ─────────────────────────────────────────────────────────

  @doc "Creates a new empty font registry."
  @spec new_font_registry() :: Minga.UI.FontRegistry.t()
  defdelegate new_font_registry, to: Minga.UI.FontRegistry, as: :new
end
