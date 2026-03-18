defmodule Minga.Face.SparsityPropertyTest do
  @moduledoc """
  Property-based tests verifying the style sparsity contract.

  The render pipeline relies on style sparsity as a semantic signal:
  `buffer_line.ex` checks `Keyword.has_key?(style, :bg)` to decide
  whether a token has an explicit background or should inherit the
  cursorline/decoration bg. Any violation of this contract breaks
  cursorline rendering.

  These tests use StreamData to generate random Face structs and verify
  the sparsity invariant holds across all possible face configurations.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StreamData

  alias Minga.Face
  alias Minga.Face.Registry

  # ── Generators ──

  defp color_gen do
    integer(0x000000..0xFFFFFF)
  end

  defp optional_color_gen do
    one_of([constant(nil), color_gen()])
  end

  defp face_gen(name, base) do
    gen all(
          fg <- optional_color_gen(),
          bg <- optional_color_gen(),
          bold <- one_of([constant(nil), boolean()]),
          italic <- one_of([constant(nil), boolean()]),
          underline <- one_of([constant(nil), boolean()]),
          strikethrough <- one_of([constant(nil), boolean()]),
          blend <- one_of([constant(nil), integer(0..100)])
        ) do
      %Face{
        name: name,
        inherit: "default",
        fg: fg,
        bg: bg,
        bold: bold,
        italic: italic,
        underline: underline,
        strikethrough: strikethrough,
        blend: blend
      }
      |> Face.resolve(fn "default" -> base end)
    end
  end

  # ── Properties ──

  property "to_style never emits :bg when face.bg matches base.bg" do
    base = Face.default()

    check all(face <- face_gen("test", base)) do
      style = Face.to_style(face, base)

      if Keyword.has_key?(style, :bg) do
        assert Keyword.get(style, :bg) != base.bg,
               "to_style emitted bg=#{inspect(Keyword.get(style, :bg))} which matches base bg=#{inspect(base.bg)}"
      end
    end
  end

  property "to_style never emits :fg when face.fg matches base.fg" do
    base = Face.default()

    check all(face <- face_gen("test", base)) do
      style = Face.to_style(face, base)

      if Keyword.has_key?(style, :fg) do
        assert Keyword.get(style, :fg) != base.fg,
               "to_style emitted fg=#{inspect(Keyword.get(style, :fg))} which matches base fg=#{inspect(base.fg)}"
      end
    end
  end

  property "to_style omits :bold when face.bold is false" do
    base = Face.default()

    check all(face <- face_gen("test", base)) do
      style = Face.to_style(face, base)

      if Keyword.has_key?(style, :bold) do
        assert Keyword.get(style, :bold) == true
      end
    end
  end

  property "to_style omits :blend when face.blend is 100 (fully opaque)" do
    base = Face.default()

    check all(face <- face_gen("test", base)) do
      style = Face.to_style(face, base)

      if Keyword.has_key?(style, :blend) do
        assert Keyword.get(style, :blend) < 100
      end
    end
  end

  property "style_for on a theme registry produces sparse styles" do
    theme = Minga.Theme.get!(:doom_one)
    reg = Registry.from_theme(theme)
    base = Registry.resolve(reg, "default")

    # All capture names from doom_one's syntax map
    names = Registry.names(reg)

    check all(name <- member_of(names)) do
      face = Registry.style_for(reg, name)

      # For faces that have a bg matching the default, to_style should NOT emit bg
      # This tests that to_style still produces sparse output for the protocol layer
      style_kw = Face.to_style(face, base)

      if face.bg == base.bg do
        refute Keyword.has_key?(style_kw, :bg),
               "to_style for #{inspect(name)} emitted bg=#{inspect(face.bg)} which matches default bg=#{inspect(base.bg)}"
      end
    end
  end

  property "cursorline contract: absent :bg allows cursorline tinting" do
    base = Face.default()

    check all(face <- face_gen("keyword", base)) do
      style = Face.to_style(face, base)

      # Simulate buffer_line.ex logic
      has_explicit_bg = Keyword.has_key?(style, :bg)

      if face.bg == base.bg do
        # Face inherited default bg — cursorline should be able to tint
        refute has_explicit_bg,
               "Face with inherited bg should not emit :bg (blocks cursorline tinting)"
      end
    end
  end
end
