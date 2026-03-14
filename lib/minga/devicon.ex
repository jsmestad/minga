defmodule Minga.Devicon do
  @moduledoc """
  Maps filetypes and special buffer types to Nerd Font icons and colors.

  Language filetypes are looked up from the `Minga.Language.Registry` at
  runtime. Special buffer types (agent, messages, help) are
  hardcoded since they aren't languages.

  Used by the tab bar, file tree, buffer picker, and anywhere else that
  displays a filename alongside a visual indicator.
  """

  alias Minga.Language.Registry, as: LangRegistry

  @type filetype :: atom()

  # Default icon and color for unknown filetypes
  @default_icon "\u{E612}"
  @default_color 0x6D8086

  @doc "Returns the Nerd Font icon for the given filetype."
  @spec icon(filetype()) :: String.t()
  def icon(ft), do: elem(icon_and_color(ft), 0)

  @doc "Returns the 24-bit RGB color for the given filetype."
  @spec color(filetype()) :: non_neg_integer()
  def color(ft), do: elem(icon_and_color(ft), 1)

  @doc "Returns `{icon, color}` for the given filetype."
  @spec icon_and_color(filetype()) :: {String.t(), non_neg_integer()}

  # ── Special buffer types (not languages, no Language definition) ───────────

  def icon_and_color(:agent), do: {"\u{F06A9}", 0x7EC8E3}
  def icon_and_color(:messages), do: {"\u{F0369}", 0x519ABA}
  def icon_and_color(:help), do: {"\u{F02D7}", 0x00ADD8}

  # ── Language-backed lookup ─────────────────────────────────────────────────

  def icon_and_color(filetype) when is_atom(filetype) do
    case LangRegistry.get(filetype) do
      %{icon: icon, icon_color: color} when is_binary(icon) and is_integer(color) ->
        {icon, color}

      _ ->
        {@default_icon, @default_color}
    end
  end
end
