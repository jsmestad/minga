defmodule MingaNewTest do
  use ExUnit.Case, async: true

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "minga_new_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, dir: test_dir}
  end

  test "generates a valid extension project", %{dir: dir} do
    name = "test_extension"
    path = Path.join(dir, name)

    Mix.Tasks.Minga.New.run([name, "--path", path])

    assert File.exists?(Path.join(path, "mix.exs"))
    assert File.exists?(Path.join(path, "lib/test_extension.ex"))
    assert File.exists?(Path.join(path, "lib/test_extension/commands.ex"))
    assert File.exists?(Path.join(path, "test/test_extension_test.exs"))
    assert File.exists?(Path.join(path, "test/test_helper.exs"))
    assert File.exists?(Path.join(path, ".formatter.exs"))
    assert File.exists?(Path.join(path, ".gitignore"))

    mix_content = File.read!(Path.join(path, "mix.exs"))
    assert mix_content =~ "minga_sdk"
    assert mix_content =~ ":test_extension"

    ext_content = File.read!(Path.join(path, "lib/test_extension.ex"))
    assert ext_content =~ "use Minga.Extension"
    assert ext_content =~ "TestExtension"
    assert ext_content =~ ":test_extension"
  end

  test "raises on existing directory", %{dir: dir} do
    path = Path.join(dir, "existing")
    File.mkdir_p!(path)

    assert_raise Mix.Error, ~r/already exists/, fn ->
      Mix.Tasks.Minga.New.run(["existing", "--path", path])
    end
  end

  test "raises without a name" do
    assert_raise Mix.Error, ~r/Expected extension name/, fn ->
      Mix.Tasks.Minga.New.run([])
    end
  end
end
