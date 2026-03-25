defmodule Minga.ThemeTest do
  use ExUnit.Case, async: true

  alias Minga.UI.Theme

  describe "available/0" do
    test "returns 7 built-in themes" do
      themes = Theme.available()
      assert length(themes) == 7
      assert :doom_one in themes
      assert :catppuccin_frappe in themes
      assert :catppuccin_latte in themes
      assert :catppuccin_macchiato in themes
      assert :catppuccin_mocha in themes
      assert :one_dark in themes
      assert :one_light in themes
    end
  end

  describe "default/0" do
    test "returns :doom_one" do
      assert Theme.default() == :doom_one
    end
  end

  describe "get/1" do
    test "returns {:ok, theme} for valid name" do
      assert {:ok, %Theme{name: :doom_one}} = Theme.get(:doom_one)
    end

    test "returns :error for invalid name" do
      assert :error = Theme.get(:nonexistent)
    end
  end

  describe "get!/1" do
    test "returns theme struct for valid name" do
      theme = Theme.get!(:doom_one)
      assert %Theme{name: :doom_one} = theme
    end

    test "raises for invalid name" do
      assert_raise ArgumentError, ~r/unknown theme/, fn ->
        Theme.get!(:nonexistent)
      end
    end
  end

  describe "style_for_capture/2" do
    test "exact match" do
      theme = Theme.get!(:doom_one)
      style = Theme.style_for_capture(theme, "keyword")
      assert Keyword.get(style, :bold) == true
      assert is_integer(Keyword.get(style, :fg))
    end

    test "suffix fallback" do
      theme = Theme.get!(:doom_one)
      style = Theme.style_for_capture(theme, "keyword.unknown.deep")
      assert Keyword.get(style, :bold) == true
    end

    test "returns empty list for unknown capture" do
      theme = Theme.get!(:doom_one)
      assert Theme.style_for_capture(theme, "nonexistent") == []
    end
  end

  describe "all themes are valid" do
    for theme_name <- [
          :doom_one,
          :catppuccin_frappe,
          :catppuccin_latte,
          :catppuccin_macchiato,
          :catppuccin_mocha,
          :one_dark,
          :one_light
        ] do
      test "#{theme_name} has all required fields" do
        theme = Theme.get!(unquote(theme_name))
        assert %Theme{} = theme
        assert theme.name == unquote(theme_name)

        # Editor colors
        assert is_integer(theme.editor.bg)
        assert is_integer(theme.editor.fg)
        assert is_integer(theme.editor.tilde_fg)
        assert is_integer(theme.editor.split_border_fg)

        # Gutter colors
        assert is_integer(theme.gutter.fg)
        assert is_integer(theme.gutter.current_fg)
        assert is_integer(theme.gutter.error_fg)
        assert is_integer(theme.gutter.warning_fg)
        assert is_integer(theme.gutter.info_fg)
        assert is_integer(theme.gutter.hint_fg)

        # Modeline colors
        assert is_integer(theme.modeline.bar_fg)
        assert is_integer(theme.modeline.bar_bg)
        assert is_integer(theme.modeline.info_fg)
        assert is_integer(theme.modeline.info_bg)
        assert is_integer(theme.modeline.filetype_fg)
        assert is_map(theme.modeline.mode_colors)
        assert map_size(theme.modeline.mode_colors) >= 7

        for {_mode, {fg, bg}} <- theme.modeline.mode_colors do
          assert is_integer(fg)
          assert is_integer(bg)
        end

        # Picker colors
        assert is_integer(theme.picker.bg)
        assert is_integer(theme.picker.sel_bg)
        assert is_integer(theme.picker.text_fg)
        assert is_integer(theme.picker.match_fg)

        # Minibuffer colors
        assert is_integer(theme.minibuffer.fg)
        assert is_integer(theme.minibuffer.bg)
        assert is_integer(theme.minibuffer.warning_fg)
        assert is_integer(theme.minibuffer.dim_fg)

        # Search colors
        assert is_integer(theme.search.highlight_fg)
        assert is_integer(theme.search.highlight_bg)
        assert is_integer(theme.search.current_bg)

        # Popup colors
        assert is_integer(theme.popup.fg)
        assert is_integer(theme.popup.bg)
        assert is_integer(theme.popup.border_fg)

        # Tree colors
        assert is_integer(theme.tree.bg)
        assert is_integer(theme.tree.fg)
        assert is_integer(theme.tree.dir_fg)
        assert is_integer(theme.tree.active_fg)
        assert is_integer(theme.tree.cursor_bg)
        assert is_integer(theme.tree.header_fg)
        assert is_integer(theme.tree.header_bg)
        assert is_integer(theme.tree.separator_fg)
      end

      test "#{theme_name} has syntax entries for common captures" do
        theme = Theme.get!(unquote(theme_name))

        common_captures = [
          "keyword",
          "string",
          "comment",
          "function",
          "type",
          "variable",
          "number",
          "operator"
        ]

        for capture <- common_captures do
          style = Theme.style_for_capture(theme, capture)
          assert is_list(style), "expected style list for #{capture} in #{unquote(theme_name)}"

          assert Keyword.has_key?(style, :fg),
                 "expected :fg in style for #{capture} in #{unquote(theme_name)}"
        end
      end

      test "#{theme_name} has markup entries for markdown highlighting" do
        theme = Theme.get!(unquote(theme_name))

        markup_captures = [
          "markup.heading",
          "markup.heading.1",
          "markup.heading.2",
          "markup.heading.3",
          "markup.heading.4",
          "markup.heading.5",
          "markup.heading.6",
          "markup.bold",
          "markup.strong",
          "markup.italic",
          "markup.strikethrough",
          "markup.raw",
          "markup.raw.block",
          "markup.link",
          "markup.link.url",
          "markup.link.label",
          "markup.list",
          "markup.list.checked",
          "markup.list.unchecked",
          "markup.quote"
        ]

        for capture <- markup_captures do
          style = Theme.style_for_capture(theme, capture)
          assert is_list(style), "expected style list for #{capture} in #{unquote(theme_name)}"

          assert Keyword.has_key?(style, :fg),
                 "expected :fg in style for #{capture} in #{unquote(theme_name)}"
        end
      end

      test "#{theme_name} heading levels have distinct colors" do
        theme = Theme.get!(unquote(theme_name))

        heading_colors =
          for level <- 1..6 do
            style = Theme.style_for_capture(theme, "markup.heading.#{level}")
            Keyword.get(style, :fg)
          end

        unique_colors = Enum.uniq(heading_colors)
        # At least 4 distinct colors across 6 heading levels
        assert length(unique_colors) >= 4,
               "expected at least 4 distinct heading colors in #{unquote(theme_name)}, got #{length(unique_colors)}: #{inspect(heading_colors)}"
      end

      test "#{theme_name} color groups are proper structs" do
        theme = Theme.get!(unquote(theme_name))
        assert %Theme.Editor{} = theme.editor
        assert %Theme.Gutter{} = theme.gutter
        assert %Theme.Modeline{} = theme.modeline
        assert %Theme.Picker{} = theme.picker
        assert %Theme.Minibuffer{} = theme.minibuffer
        assert %Theme.Search{} = theme.search
        assert %Theme.Popup{} = theme.popup
        assert %Theme.Tree{} = theme.tree
      end

      test "#{theme_name} has agent colors" do
        theme = Theme.get!(unquote(theme_name))
        assert %Theme.Agent{} = theme.agent
        assert theme.agent != nil

        agent_fields = [
          :panel_bg,
          :panel_border,
          :header_fg,
          :header_bg,
          :user_border,
          :user_label,
          :assistant_border,
          :assistant_label,
          :tool_border,
          :tool_header,
          :code_bg,
          :code_border,
          :input_border,
          :input_bg,
          :input_placeholder,
          :thinking_fg,
          :status_thinking,
          :status_tool,
          :status_error,
          :status_idle,
          :text_fg,
          :context_low,
          :context_mid,
          :context_high,
          :usage_fg,
          :toast_bg,
          :toast_fg,
          :toast_border,
          :system_fg,
          :search_match_bg,
          :search_current_bg
        ]

        for field <- agent_fields do
          value = Map.get(theme.agent, field)

          assert is_integer(value) and value >= 0,
                 "expected #{field} to be a non-negative integer in #{unquote(theme_name)}.agent, got: #{inspect(value)}"
        end
      end

      test "#{theme_name} all colors are non-negative integers" do
        theme = Theme.get!(unquote(theme_name))

        for {_key, color} <- Map.from_struct(theme.editor) do
          assert is_integer(color) and color >= 0
        end

        for {_key, color} <- Map.from_struct(theme.gutter), color != nil do
          assert is_integer(color) and color >= 0
        end

        for {_key, color} <- Map.from_struct(theme.tree) do
          assert is_integer(color) and color >= 0
        end

        for {_key, color} <- Map.from_struct(theme.agent) do
          assert is_integer(color) and color >= 0
        end
      end
    end
  end

  describe "light vs dark themes" do
    test "latte has a light background" do
      theme = Theme.get!(:catppuccin_latte)
      # Latte's base is 0xEFF1F5, a very light color
      assert theme.editor.bg > 0xC0C0C0
    end

    test "one_light has a light background" do
      theme = Theme.get!(:one_light)
      assert theme.editor.bg > 0xC0C0C0
    end

    test "doom_one has a dark background" do
      theme = Theme.get!(:doom_one)
      assert theme.editor.bg < 0x404040
    end

    test "catppuccin_mocha has a dark background" do
      theme = Theme.get!(:catppuccin_mocha)
      assert theme.editor.bg < 0x404040
    end
  end

  describe "agent theme fallback" do
    test "agent_theme/1 returns fallback when agent is nil" do
      theme = %Theme{
        name: :test,
        syntax: %{},
        editor: Theme.get!(:doom_one).editor,
        gutter: Theme.get!(:doom_one).gutter,
        git: Theme.get!(:doom_one).git,
        modeline: Theme.get!(:doom_one).modeline,
        picker: Theme.get!(:doom_one).picker,
        minibuffer: Theme.get!(:doom_one).minibuffer,
        search: Theme.get!(:doom_one).search,
        popup: Theme.get!(:doom_one).popup,
        tree: Theme.get!(:doom_one).tree,
        agent: nil
      }

      agent = Theme.agent_theme(theme)
      assert %Theme.Agent{} = agent
      assert is_integer(agent.panel_bg)
      assert is_integer(agent.context_low)
      assert is_integer(agent.search_match_bg)
    end

    test "agent_theme/1 returns the theme's agent when present" do
      theme = Theme.get!(:catppuccin_mocha)
      agent = Theme.agent_theme(theme)
      assert agent == theme.agent
    end
  end

  describe "agent_syntax/1" do
    test "overrides delimiter captures with delimiter_dim color" do
      theme = Theme.get!(:doom_one)
      syntax = Theme.agent_syntax(theme)
      agent = Theme.agent_theme(theme)

      assert syntax["punctuation.delimiter"] == [fg: agent.delimiter_dim]
      assert syntax["punctuation.special"] == [fg: agent.delimiter_dim]
    end

    test "overrides link captures with agent colors" do
      theme = Theme.get!(:doom_one)
      syntax = Theme.agent_syntax(theme)
      agent = Theme.agent_theme(theme)

      assert syntax["markup.link.label"] == [fg: agent.link_fg]
      assert syntax["markup.link.url"] == [fg: agent.delimiter_dim]
    end

    test "maps per-level heading captures to heading colors" do
      theme = Theme.get!(:doom_one)
      syntax = Theme.agent_syntax(theme)
      agent = Theme.agent_theme(theme)

      assert syntax["markup.heading.1"] == [fg: agent.heading1_fg, bold: true]
      assert syntax["markup.heading.2"] == [fg: agent.heading2_fg, bold: true]
      assert syntax["markup.heading.3"] == [fg: agent.heading3_fg, bold: true]
      # h4-h6 fall back to heading3 color without bold
      assert syntax["markup.heading.4"] == [fg: agent.heading3_fg]
    end

    test "preserves non-overridden captures from base syntax" do
      theme = Theme.get!(:doom_one)
      syntax = Theme.agent_syntax(theme)

      # keyword, string, etc. should come from the base theme
      assert syntax["keyword"] == theme.syntax["keyword"]
      assert syntax["string"] == theme.syntax["string"]
      assert syntax["comment"] == theme.syntax["comment"]
    end

    test "works for all themes" do
      for name <- Theme.available() do
        theme = Theme.get!(name)
        syntax = Theme.agent_syntax(theme)
        agent = Theme.agent_theme(theme)

        assert syntax["punctuation.delimiter"] == [fg: agent.delimiter_dim],
               "#{name}: punctuation.delimiter should use delimiter_dim"

        assert syntax["markup.link.label"] == [fg: agent.link_fg],
               "#{name}: markup.link.label should use link_fg"
      end
    end
  end

  describe "agent theme consistency" do
    test "light themes have light agent panel backgrounds" do
      for name <- [:catppuccin_latte, :one_light] do
        theme = Theme.get!(name)
        assert theme.agent.panel_bg > 0xC0C0C0, "#{name} agent.panel_bg should be light"
      end
    end

    test "dark themes have dark agent panel backgrounds" do
      for name <- [:doom_one, :catppuccin_mocha, :catppuccin_macchiato, :one_dark] do
        theme = Theme.get!(name)
        assert theme.agent.panel_bg < 0x404040, "#{name} agent.panel_bg should be dark"
      end
    end
  end
end
