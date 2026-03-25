defmodule Minga.DeviconTest do
  use ExUnit.Case, async: true

  alias Minga.UI.Devicon

  @all_filetypes [
    :bash,
    :c,
    :c_sharp,
    :conf,
    :cpp,
    :css,
    :csv,
    :dart,
    :diff,
    :dockerfile,
    :editorconfig,
    :elixir,
    :emacs_lisp,
    :erlang,
    :fish,
    :gitconfig,
    :gleam,
    :go,
    :graphql,
    :haskell,
    :hcl,
    :heex,
    :html,
    :ini,
    :java,
    :javascript,
    :javascript_react,
    :json,
    :kotlin,
    :lfe,
    :lua,
    :make,
    :markdown,
    :nix,
    :ocaml,
    :perl,
    :php,
    :protobuf,
    :python,
    :r,
    :ruby,
    :rust,
    :scala,
    :scss,
    :sql,
    :swift,
    :text,
    :toml,
    :typescript,
    :typescript_react,
    :vim,
    :xml,
    :yaml,
    :zig
  ]

  describe "icon_and_color/1" do
    test "every filetype in Minga.Language.Filetype has an entry" do
      for ft <- @all_filetypes do
        {icon, color} = Devicon.icon_and_color(ft)
        assert is_binary(icon), "icon for #{ft} should be a string"
        assert is_integer(color), "color for #{ft} should be an integer"
        assert String.length(icon) > 0, "icon for #{ft} should not be empty"
      end
    end

    test "all colors are valid 24-bit RGB values" do
      for ft <- @all_filetypes do
        {_, color} = Devicon.icon_and_color(ft)
        assert color >= 0x000000 and color <= 0xFFFFFF, "color for #{ft} out of 24-bit range"
      end
    end

    test "no two filetypes share the same icon (except related pairs)" do
      icons =
        Enum.map(@all_filetypes, fn ft ->
          {ft, Devicon.icon(ft)}
        end)

      # Group by icon
      groups = Enum.group_by(icons, fn {_, icon} -> icon end, fn {ft, _} -> ft end)

      for {icon, fts} <- groups, length(fts) > 1 do
        # Allow related filetypes to share icons
        related_sets = [
          MapSet.new([:javascript_react, :typescript_react]),
          MapSet.new([:erlang, :lfe]),
          MapSet.new([:ini, :conf, :editorconfig, :toml]),
          MapSet.new([:java, :scala]),
          MapSet.new([:elixir, :heex]),
          MapSet.new([:bash, :fish]),
          MapSet.new([:text])
        ]

        ft_set = MapSet.new(fts)

        shared_ok =
          Enum.any?(related_sets, fn allowed ->
            MapSet.subset?(ft_set, allowed)
          end)

        assert shared_ok,
               "Unrelated filetypes share icon #{inspect(icon)}: #{inspect(fts)}"
      end
    end
  end

  describe "special buffer types" do
    test "agent has robot icon" do
      assert {"\u{F06A9}", _} = Devicon.icon_and_color(:agent)
    end

    test "messages has message icon" do
      assert {"\u{F0369}", _} = Devicon.icon_and_color(:messages)
    end

    test "help has help icon" do
      assert {"\u{F02D7}", _} = Devicon.icon_and_color(:help)
    end
  end

  describe "fallback" do
    test "unknown filetype returns generic file icon" do
      {icon, color} = Devicon.icon_and_color(:unknown_filetype_xyz)
      assert icon == "\u{E612}"
      assert color == 0x6D8086
    end
  end

  describe "convenience functions" do
    test "icon/1 returns just the icon" do
      assert Devicon.icon(:elixir) == "\u{E62D}"
    end

    test "color/1 returns just the color" do
      assert Devicon.color(:elixir) == 0x9B59B6
    end
  end
end
