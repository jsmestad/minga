defmodule MingaAgent.Tools.PathIgnoreTest do
  # Serializes because git-backed filter tests spawn real OS processes.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.PathIgnore

  @moduletag :tmp_dir

  describe "ignored_name?/1" do
    test "treats env variants and npmrc as ignored" do
      assert PathIgnore.ignored_name?(".env")
      assert PathIgnore.ignored_name?(".env.local")
      assert PathIgnore.ignored_name?(".env.example")
      assert PathIgnore.ignored_name?(".npmrc")
    end
  end

  describe "ignored_path?/1" do
    test "treats any ignored path segment as ignored" do
      dir =
        Path.join(System.tmp_dir!(), "minga-path-ignore-#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "lib"))
      on_exit(fn -> File.rm_rf!(dir) end)

      assert PathIgnore.ignored_path?(Path.join([dir, "node_modules", "pkg"]))
      assert PathIgnore.ignored_path?(Path.join([dir, "lib", ".env.local"]))
      refute PathIgnore.ignored_path?(Path.join([dir, "lib", "visible.ex"]))
    end
  end

  describe "filter_paths/2" do
    @tag :heavy
    test "drops gitignored paths and secret env files while keeping visible results", %{
      tmp_dir: dir
    } do
      {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      File.write!(Path.join(dir, ".gitignore"), "ignored_dir/\n")

      assert PathIgnore.filter_paths(dir, [
               "visible.ex",
               "ignored_dir/leaked.ex",
               ".env.local",
               ".npmrc"
             ]) == ["visible.ex"]
    end
  end

  describe "filter_grep_lines/2" do
    @tag :heavy
    test "drops gitignored result lines and keeps visible results", %{tmp_dir: dir} do
      {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      File.write!(Path.join(dir, ".gitignore"), "ignored_dir/\n")

      assert PathIgnore.filter_grep_lines(dir, [
               "visible.ex:1:visible",
               "visible.ex-1-visible",
               "ignored_dir/leaked.ex:1:secret",
               "ignored_dir/leaked.ex-1-secret",
               ".env.local:2:secret",
               ".npmrc:3:secret"
             ]) == ["visible.ex:1:visible", "visible.ex-1-visible"]
    end
  end
end
