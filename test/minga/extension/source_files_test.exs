defmodule Minga.Extension.SourceFilesTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.SourceFiles

  @moduletag :tmp_dir

  defp touch!(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end

  defp relative(root, files), do: Enum.map(files, &Path.relative_to(&1, root))

  test "a Mix project compiles only its lib sources", %{tmp_dir: root} do
    touch!(root, "mix.exs")
    touch!(root, "lib/my_ext.ex")
    touch!(root, "lib/my_ext/route.ex")
    touch!(root, "deps/minga_sdk/lib/minga/extension.ex")
    touch!(root, "_build/dev/lib/my_ext/consolidated.ex")
    touch!(root, "test/support/fake.ex")
    touch!(root, "config/config.ex")

    assert relative(root, SourceFiles.list(root)) == ["lib/my_ext.ex", "lib/my_ext/route.ex"]
  end

  test "a plain directory skips dependencies, build output, tests, and hidden folders", %{
    tmp_dir: root
  } do
    touch!(root, "my_ext.ex")
    touch!(root, "helpers/format.ex")
    touch!(root, "deps/other/lib/other.ex")
    touch!(root, "_build/dev/x.ex")
    touch!(root, "test/support/fake.ex")
    touch!(root, ".elixir_ls/build/y.ex")

    assert relative(root, SourceFiles.list(root)) == ["helpers/format.ex", "my_ext.ex"]
  end

  test "a Mix project with fetched dependencies stays under the source file limit", %{
    tmp_dir: root
  } do
    touch!(root, "mix.exs")
    touch!(root, "lib/my_ext.ex")
    for n <- 1..200, do: touch!(root, "deps/big_dep/lib/mod_#{n}.ex")

    assert relative(root, SourceFiles.list(root)) == ["lib/my_ext.ex"]
  end

  test "an empty directory has no sources", %{tmp_dir: root} do
    assert SourceFiles.list(root) == []
  end
end
