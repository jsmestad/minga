defmodule Minga.DeviconTest do
  use ExUnit.Case, async: true

  alias Minga.Devicon

  @all_filetypes [
    :elixir,
    :erlang,
    :heex,
    :lfe,
    :gleam,
    :zig,
    :rust,
    :go,
    :c,
    :cpp,
    :c_sharp,
    :java,
    :kotlin,
    :scala,
    :python,
    :ruby,
    :javascript,
    :javascript_react,
    :typescript,
    :typescript_react,
    :lua,
    :bash,
    :fish,
    :php,
    :perl,
    :r,
    :haskell,
    :ocaml,
    :swift,
    :dart,
    :nix,
    :emacs_lisp,
    :vim,
    :html,
    :css,
    :scss,
    :markdown,
    :json,
    :yaml,
    :toml,
    :xml,
    :graphql,
    :sql,
    :csv,
    :protobuf,
    :hcl,
    :dockerfile,
    :make,
    :gitconfig,
    :editorconfig,
    :conf,
    :ini,
    :diff,
    :text
  ]

  @special_types [:agent, :messages, :scratch, :help]

  describe "icon/1" do
    test "every filetype from Minga.Filetype has an icon" do
      for ft <- @all_filetypes do
        icon = Devicon.icon(ft)
        assert is_binary(icon), "#{ft} should return a string icon"
        assert icon != "", "#{ft} should not return empty string"
      end
    end

    test "special buffer types have icons" do
      for ft <- @special_types do
        icon = Devicon.icon(ft)
        assert is_binary(icon), "#{ft} should return a string icon"
        assert icon != "", "#{ft} should not return empty string"
      end
    end

    test "unknown filetype returns fallback icon" do
      assert Devicon.icon(:nonexistent_lang) == "\u{F15B}"
    end

    test "agent icon is the robot" do
      assert Devicon.icon(:agent) == "\u{F06A9}"
    end
  end

  describe "color/1" do
    test "every filetype returns a valid 24-bit color" do
      for ft <- @all_filetypes ++ @special_types do
        color = Devicon.color(ft)
        assert is_integer(color), "#{ft} color should be an integer"

        assert color >= 0x000000 and color <= 0xFFFFFF,
               "#{ft} color 0x#{Integer.to_string(color, 16)} out of range"
      end
    end

    test "unknown filetype returns a valid fallback color" do
      color = Devicon.color(:nonexistent_lang)
      assert is_integer(color)
      assert color >= 0x000000 and color <= 0xFFFFFF
    end

    test "elixir is purple" do
      assert Devicon.color(:elixir) == 0x9B59B6
    end
  end

  describe "icon_and_color/1" do
    test "returns a tuple of {icon, color}" do
      {icon, color} = Devicon.icon_and_color(:elixir)
      assert icon == Devicon.icon(:elixir)
      assert color == Devicon.color(:elixir)
    end

    test "fallback returns tuple" do
      {icon, color} = Devicon.icon_and_color(:nonexistent_lang)
      assert icon == "\u{F15B}"
      assert is_integer(color)
    end
  end
end
