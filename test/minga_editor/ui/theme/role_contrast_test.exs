defmodule MingaEditor.UI.Theme.RoleContrastTest do
  @moduledoc """
  Every built-in theme defines every design-token colour role and meets the contrast targets in `docs/design/themes.md`.
  """

  use ExUnit.Case, async: true

  alias Minga.Design.Tokens
  alias Minga.Extensions.ThemePacks
  alias MingaEditor.UI.Theme

  @theme_modules [Theme.Fallback | ThemePacks.AstroNvim.theme_modules()] ++
                   ThemePacks.Catppuccin.theme_modules() ++
                   ThemePacks.Doom.theme_modules() ++
                   ThemePacks.One.theme_modules()

  test "the built-in theme list covers the three reference themes" do
    names = Enum.map(@theme_modules, & &1.theme().name)

    for name <- [:catppuccin_frappe, :astrodark, :catppuccin_latte] do
      assert name in names
    end
  end

  for module <- @theme_modules do
    @module module

    test "#{inspect(module)} gives every colour role a colour" do
      theme = @module.theme()

      for role <- Tokens.color_roles() do
        assert is_integer(Theme.role_color(theme, role)),
               "#{theme.name} has no colour for the #{role} role"
      end
    end

    test "#{inspect(module)} meets the contrast target of every role" do
      theme = @module.theme()

      failures =
        for role <- Tokens.color_roles(),
            {class, on} <- List.wrap(Tokens.color_role(role).contrast),
            ratio = contrast(Theme.role_color(theme, role), Theme.role_color(theme, on)),
            ratio < Tokens.contrast_target(class) do
          "#{role} on #{on}: #{Float.round(ratio, 2)} < #{Tokens.contrast_target(class)} (#{class})"
        end

      assert failures == [],
             "#{theme.name} misses contrast targets:\n" <> Enum.join(failures, "\n")
    end
  end

  test "a kept strand is quieter than the pending strand without losing glyph contrast" do
    for module <- @theme_modules do
      theme = module.theme()
      surface = Theme.role_color(theme, :surface)
      kept = contrast(Theme.role_color(theme, :minga_kept), surface)
      pending = contrast(Theme.role_color(theme, :minga), surface)

      assert kept >= Tokens.contrast_target(:glyph) and kept < pending,
             "#{theme.name} must keep the muted strand visible and distinct"
    end
  end

  # The border role is sent as popup.border_fg; pane splits draw editor.split_border_fg and are held to the same target.
  test "pane split borders meet the border role's contrast target in every theme" do
    {class, on} = Tokens.color_role(:border).contrast

    failures =
      for module <- @theme_modules,
          theme = module.theme(),
          ratio = contrast(theme.editor.split_border_fg, Theme.role_color(theme, on)),
          ratio < Tokens.contrast_target(class) do
        "#{theme.name}: split border #{Float.round(ratio, 2)} < #{Tokens.contrast_target(class)}"
      end

    assert failures == [], Enum.join(failures, "\n")
  end

  test "needs_you, failure and done keep distinct colours in every theme" do
    for module <- @theme_modules do
      theme = module.theme()

      colours =
        Enum.map([:minga, :needs_you, :failure, :done, :warning], &Theme.role_color(theme, &1))

      assert Enum.uniq(colours) == colours,
             "#{theme.name} reuses one colour for two of minga, needs_you, failure, done and warning"
    end
  end

  test "the assistant label and the thinking status are drawn in the minga role" do
    for module <- @theme_modules do
      theme = module.theme()
      agent = Theme.agent_theme(theme)
      minga = Theme.role_color(theme, :minga)

      assert agent.assistant_label == minga, "#{theme.name} assistant_label is not the minga role"
      assert agent.status_thinking == minga, "#{theme.name} status_thinking is not the minga role"
    end
  end

  test "every role keeps a colour when a theme leaves optional fields nil" do
    theme = Theme.CatppuccinFrappe.theme()
    theme = %{theme | agent: nil, popup: %{theme.popup | title_fg: nil, group_fg: nil}}

    for role <- Tokens.color_roles() do
      assert is_integer(Theme.role_color(theme, role)), "no colour for #{role}"
    end

    assert Theme.role_color(theme, :focus) == theme.modeline.filetype_fg
    assert Theme.role_color(theme, :group) == theme.popup.fg
  end

  test "states resolve through their colour role" do
    theme = Theme.CatppuccinFrappe.theme()

    for state <- Tokens.state_ids() do
      assert Theme.state_color(theme, state) == Theme.role_color(theme, Tokens.state_role(state))
    end

    assert Theme.state_color(theme, :needs_you) == Theme.agent_theme(theme).attention_fg
  end

  test "minga_shade is minga mixed over the editor background" do
    theme = Theme.CatppuccinFrappe.theme()
    shade = Theme.role_color(theme, :minga_shade)

    assert shade != Theme.role_color(theme, :minga)
    assert shade != theme.editor.bg

    assert contrast(shade, theme.editor.bg) <
             contrast(Theme.role_color(theme, :minga), theme.editor.bg)
  end

  # WCAG 2 contrast ratio between two 0xRRGGBB colours.
  @spec contrast(non_neg_integer(), non_neg_integer()) :: float()
  defp contrast(a, b) do
    [lighter, darker] = Enum.sort([luminance(a), luminance(b)], :desc)
    (lighter + 0.05) / (darker + 0.05)
  end

  @spec luminance(non_neg_integer()) :: float()
  defp luminance(rgb) do
    [r, g, b] =
      for shift <- [16, 8, 0] do
        channel = Bitwise.band(Bitwise.bsr(rgb, shift), 0xFF) / 255

        if channel <= 0.03928,
          do: channel / 12.92,
          else: :math.pow((channel + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end
end
