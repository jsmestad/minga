defmodule Minga.Language.Devicon do
  @moduledoc """
  Maps filetypes and special buffer types to Nerd Font icons and colors.

  Language filetypes are looked up from the `Minga.Language.Registry` at
  runtime. Special buffer types (agent, messages, help) are
  hardcoded since they aren't languages.

  Used by the tab bar, file tree, buffer picker, and anywhere else that
  displays a filename alongside a visual indicator.
  """

  alias Minga.Language

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
    case Language.get(filetype) do
      %{icon: icon, icon_color: color} when is_binary(icon) and is_integer(color) ->
        {icon, color}

      _ ->
        {@default_icon, @default_color}
    end
  end

  # ── Named folder icons (outline style, Material Icon Theme) ────────────────

  # Outline variants are lighter at small sizes and match VSCode's aesthetic.
  # nf-md-folder_outline
  @default_folder_icon "\u{F0256}"
  @default_folder_color 0x78909C

  @doc "Returns `{icon, color}` for a directory by name."
  @spec folder_icon_and_color(String.t()) :: {String.t(), non_neg_integer()}

  # Source / code (nf-md-folder_text_outline)
  def folder_icon_and_color("src"), do: {"\u{F1247}", 0x42A5F5}
  def folder_icon_and_color("lib"), do: {"\u{F1247}", 0x42A5F5}
  def folder_icon_and_color("app"), do: {"\u{F1247}", 0x42A5F5}
  def folder_icon_and_color("apps"), do: {"\u{F1247}", 0x42A5F5}

  # Tests (nf-md-folder_star_outline)
  def folder_icon_and_color("test"), do: {"\u{F1354}", 0x66BB6A}
  def folder_icon_and_color("tests"), do: {"\u{F1354}", 0x66BB6A}
  def folder_icon_and_color("spec"), do: {"\u{F1354}", 0x66BB6A}
  def folder_icon_and_color("__tests__"), do: {"\u{F1354}", 0x66BB6A}

  # Config / settings (nf-md-folder_cog_outline)
  def folder_icon_and_color("config"), do: {"\u{F10B5}", 0xFFCA28}
  def folder_icon_and_color("conf"), do: {"\u{F10B5}", 0xFFCA28}
  def folder_icon_and_color("settings"), do: {"\u{F10B5}", 0xFFCA28}
  def folder_icon_and_color(".config"), do: {"\u{F10B5}", 0xFFCA28}

  # Build / output (nf-md-folder_clock_outline)
  def folder_icon_and_color("build"), do: {"\u{F0DB4}", 0xFFA726}
  def folder_icon_and_color("dist"), do: {"\u{F0DB4}", 0xFFA726}
  def folder_icon_and_color("out"), do: {"\u{F0DB4}", 0xFFA726}
  def folder_icon_and_color("_build"), do: {"\u{F0DB4}", 0xFFA726}
  def folder_icon_and_color(".build"), do: {"\u{F0DB4}", 0xFFA726}
  def folder_icon_and_color("target"), do: {"\u{F0DB4}", 0xFFA726}
  def folder_icon_and_color("rel"), do: {"\u{F0DB4}", 0xFFA726}

  # Documentation (nf-md-folder_information_outline)
  def folder_icon_and_color("docs"), do: {"\u{F10ED}", 0x4FC3F7}
  def folder_icon_and_color("doc"), do: {"\u{F10ED}", 0x4FC3F7}
  def folder_icon_and_color("documentation"), do: {"\u{F10ED}", 0x4FC3F7}

  # Assets / static (nf-md-folder_heart_outline)
  def folder_icon_and_color("assets"), do: {"\u{F10B6}", 0xAB47BC}
  def folder_icon_and_color("static"), do: {"\u{F10B6}", 0xAB47BC}
  def folder_icon_and_color("public"), do: {"\u{F10B6}", 0xAB47BC}
  def folder_icon_and_color("images"), do: {"\u{F10B6}", 0xAB47BC}
  def folder_icon_and_color("media"), do: {"\u{F10B6}", 0xAB47BC}

  # Dependencies (nf-md-folder_network_outline)
  def folder_icon_and_color("deps"), do: {"\u{F0B9D}", 0x78909C}
  def folder_icon_and_color("node_modules"), do: {"\u{F0B9D}", 0x78909C}
  def folder_icon_and_color("vendor"), do: {"\u{F0B9D}", 0x78909C}
  def folder_icon_and_color("packages"), do: {"\u{F0B9D}", 0x78909C}

  # Scripts / tools (nf-md-folder_edit_outline)
  def folder_icon_and_color("scripts"), do: {"\u{F0DB6}", 0xEF5350}
  def folder_icon_and_color("bin"), do: {"\u{F0DB6}", 0xEF5350}
  def folder_icon_and_color("tools"), do: {"\u{F0DB6}", 0xEF5350}
  def folder_icon_and_color("mix"), do: {"\u{F0DB6}", 0xEF5350}

  # CI / GitHub (nf-md-folder_account_outline)
  def folder_icon_and_color(".github"), do: {"\u{F0DB0}", 0xBDBDBD}
  def folder_icon_and_color(".gitlab"), do: {"\u{F0DB0}", 0xBDBDBD}
  def folder_icon_and_color(".circleci"), do: {"\u{F0DB0}", 0xBDBDBD}

  # Hidden / VCS (nf-md-folder_alert_outline)
  def folder_icon_and_color(".git"), do: {"\u{F0DAE}", 0xF14C28}
  def folder_icon_and_color(".svn"), do: {"\u{F0DAE}", 0xF14C28}

  # Generated / cache (nf-md-folder_download_outline)
  def folder_icon_and_color(".generated"), do: {"\u{F10EB}", 0x90A4AE}
  def folder_icon_and_color("cover"), do: {"\u{F10EB}", 0x90A4AE}
  def folder_icon_and_color(".elixir_ls"), do: {"\u{F10EB}", 0x90A4AE}
  def folder_icon_and_color(".expert"), do: {"\u{F10EB}", 0x90A4AE}

  # Platform-specific (nf-md-folder_outline with language colors)
  def folder_icon_and_color("macos"), do: {"\u{F0256}", 0xBDBDBD}
  def folder_icon_and_color("ios"), do: {"\u{F0256}", 0xBDBDBD}
  def folder_icon_and_color("android"), do: {"\u{F0256}", 0x3DDC84}
  def folder_icon_and_color("go"), do: {"\u{F0256}", 0x00ADD8}
  def folder_icon_and_color("zig"), do: {"\u{F0256}", 0xF69A1B}

  # Extensions / plugins (nf-md-folder_key_outline)
  def folder_icon_and_color("extensions"), do: {"\u{F06B0}", 0x7E57C2}
  def folder_icon_and_color("plugins"), do: {"\u{F06B0}", 0x7E57C2}

  # Examples / samples (nf-md-folder_star_outline)
  def folder_icon_and_color("examples"), do: {"\u{F1354}", 0x81C784}
  def folder_icon_and_color("bench"), do: {"\u{F1354}", 0x81C784}
  def folder_icon_and_color("benchmarks"), do: {"\u{F1354}", 0x81C784}

  # Private / internal (nf-md-folder_key_outline)
  def folder_icon_and_color("priv"), do: {"\u{F06B0}", 0xA1887F}
  def folder_icon_and_color("private"), do: {"\u{F06B0}", 0xA1887F}
  def folder_icon_and_color("internal"), do: {"\u{F06B0}", 0xA1887F}

  # Installer / deploy (nf-md-folder_clock_outline)
  def folder_icon_and_color("installer"), do: {"\u{F0DB4}", 0x9CCC65}
  def folder_icon_and_color("deploy"), do: {"\u{F0DB4}", 0x9CCC65}

  # SDK (nf-md-folder_text_outline)
  def folder_icon_and_color("sdk"), do: {"\u{F1247}", 0x7986CB}

  # Agent / editor config (nf-md-folder_cog_outline)
  def folder_icon_and_color(".claude"), do: {"\u{F10B5}", 0x7EC8E3}
  def folder_icon_and_color(".pi"), do: {"\u{F10B5}", 0x7EC8E3}
  def folder_icon_and_color(".minga"), do: {"\u{F10B5}", 0x7EC8E3}

  # Project-specific
  def folder_icon_and_color("burrito_out"), do: {"\u{F10EB}", 0x90A4AE}
  def folder_icon_and_color("credo"), do: {"\u{F1354}", 0xFFCA28}

  def folder_icon_and_color(_name), do: {@default_folder_icon, @default_folder_color}
end
