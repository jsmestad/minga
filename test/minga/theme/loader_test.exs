defmodule Minga.Theme.LoaderTest do
  use ExUnit.Case, async: true

  alias Minga.Theme.Loader

  @moduletag :tmp_dir

  describe "load_file/1" do
    test "loads a minimal theme file", %{tmp_dir: dir} do
      path = Path.join(dir, "minimal.exs")

      File.write!(path, """
      %{
        name: :minimal_test,
        inherits: :doom_one,
        faces: %{
          "keyword" => [fg: 0xFF0000, bold: true]
        }
      }
      """)

      assert {:ok, loaded} = Loader.load_file(path)
      assert loaded.name == :minimal_test
      assert loaded.theme.name == :minimal_test
      assert loaded.source_path == path
      assert loaded.face_registry != nil
    end

    test "face overrides are applied to the registry", %{tmp_dir: dir} do
      path = Path.join(dir, "custom.exs")

      File.write!(path, """
      %{
        name: :custom_test,
        inherits: :doom_one,
        faces: %{
          "keyword" => [fg: 0xFF0000]
        }
      }
      """)

      {:ok, loaded} = Loader.load_file(path)
      style = Minga.Face.Registry.style_for(loaded.face_registry, "keyword")
      assert Keyword.get(style, :fg) == 0xFF0000
    end

    test "editor color overrides are applied", %{tmp_dir: dir} do
      path = Path.join(dir, "dark.exs")

      File.write!(path, """
      %{
        name: :dark_test,
        inherits: :doom_one,
        editor: %{bg: 0x111111, fg: 0xEEEEEE}
      }
      """)

      {:ok, loaded} = Loader.load_file(path)
      assert loaded.theme.editor.bg == 0x111111
      assert loaded.theme.editor.fg == 0xEEEEEE
    end

    test "theme without inherits defaults to doom_one", %{tmp_dir: dir} do
      path = Path.join(dir, "bare.exs")

      File.write!(path, """
      %{name: :bare_test}
      """)

      {:ok, loaded} = Loader.load_file(path)
      # Should have doom_one's editor colors as base
      doom = Minga.Theme.get!(:doom_one)
      assert loaded.theme.editor.bg == doom.editor.bg
    end

    test "returns error for missing name", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.exs")
      File.write!(path, "%{faces: %{}}")

      assert {:error, %{path: ^path, error: error}} = Loader.load_file(path)
      assert error =~ "must include a :name key"
    end

    test "returns error for non-map return", %{tmp_dir: dir} do
      path = Path.join(dir, "notmap.exs")
      File.write!(path, ":not_a_map")

      assert {:error, %{path: ^path, error: error}} = Loader.load_file(path)
      assert error =~ "must return a map"
    end

    test "returns error for syntax error", %{tmp_dir: dir} do
      path = Path.join(dir, "syntax.exs")
      File.write!(path, "%{name: :broken, faces: %{")

      assert {:error, %{path: ^path}} = Loader.load_file(path)
    end

    test "LSP defaults are included", %{tmp_dir: dir} do
      path = Path.join(dir, "lsp.exs")

      File.write!(path, """
      %{
        name: :lsp_test,
        inherits: :doom_one,
        faces: %{"function" => [fg: 0x51AFEF]}
      }
      """)

      {:ok, loaded} = Loader.load_file(path)
      # @lsp.type.function should inherit from function
      face = Minga.Face.Registry.resolve(loaded.face_registry, "@lsp.type.function")
      assert face.fg == 0x51AFEF
    end
  end

  describe "load_all/1" do
    test "loads all .exs files from themes dir", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "theme_a.exs"), "%{name: :theme_a}")
      File.write!(Path.join(dir, "theme_b.exs"), "%{name: :theme_b}")
      File.write!(Path.join(dir, "not_a_theme.txt"), "ignored")

      {themes, errors} = Loader.load_all(dir)

      assert Map.has_key?(themes, :theme_a)
      assert Map.has_key?(themes, :theme_b)
      assert errors == []
    end

    test "collects errors without stopping", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "good.exs"), "%{name: :good}")
      File.write!(Path.join(dir, "bad.exs"), ":not_a_map")

      {themes, errors} = Loader.load_all(dir)

      assert Map.has_key?(themes, :good)
      assert length(errors) == 1
    end

    test "returns empty for nonexistent directory" do
      {themes, errors} = Loader.load_all("/tmp/nonexistent_themes_dir_#{System.unique_integer()}")
      assert themes == %{}
      assert errors == []
    end
  end
end
