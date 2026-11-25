defmodule Minga.Project.SourcesTest do
  use ExUnit.Case, async: true

  alias Minga.Project.Root
  alias Minga.Project.Sources
  alias Minga.Project.Trust

  # A real folder under the system's temporary directory, whose own ancestors pass the rule on every platform.
  defp project(label) do
    root =
      Path.join(System.tmp_dir!(), "minga_sources_#{label}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([root, ".minga", "plugins", "good", "lib"]))
    File.mkdir_p!(Path.join([root, ".minga", "plugins", "open"]))
    File.write!(Path.join(root, ".minga.exs"), "use Minga.Config\n")
    File.write!(Path.join([root, ".minga", "mcp.json"]), "{}")
    File.write!(Path.join([root, ".minga", "plugins", "good", "lib", "good.ex"]), "")
    File.write!(Path.join([root, ".minga", "plugins", "stray_file"]), "")
    File.chmod!(Path.join([root, ".minga", "plugins", "open"]), 0o777)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, canonical} = Root.canonical_path(root)
    {root, canonical}
  end

  describe "admit/2" do
    test "returns the bytes of each config file and the canonical root of each plugin" do
      {root, canonical} = project("all")

      assert {:ok, %Sources{root: ^canonical} = sources} = Sources.admit(root)
      assert sources.user_id == Trust.current_user_id()

      assert sources.config ==
               {:ok, %{path: Path.join(canonical, ".minga.exs"), content: "use Minga.Config\n"}}

      assert sources.mcp == {:ok, %{path: Path.join(canonical, ".minga/mcp.json"), content: "{}"}}

      plugins = Path.join(canonical, ".minga/plugins")

      assert {:ok,
              %{
                folder: ^plugins,
                plugins: [
                  {"good", {:ok, good}},
                  {"open", {:error, {:writable_by_others, open}}}
                ]
              }} = sources.plugins

      assert good == Path.join(plugins, "good")
      assert open == Path.join(plugins, "open")
      assert Sources.plugin_names(sources) == ["good", "open"]
    end

    test "a project that carries nothing has every part absent" do
      root =
        Path.join(System.tmp_dir!(), "minga_sources_bare_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      assert {:ok, %Sources{config: :absent, mcp: :absent, plugins: :absent} = sources} =
               Sources.admit(root)

      assert Sources.plugin_names(sources) == []
    end

    test "a refused root gives a refusal and nothing of it is read" do
      {root, canonical} = project("refused")
      File.chmod!(root, 0o777)

      assert Sources.admit(root) == {:error, {:writable_by_others, canonical}}

      assert Sources.admit(root, user_id: Trust.current_user_id() + 1) ==
               {:error, {:not_yours, canonical}}
    end

    test "one refused part leaves the others usable" do
      {root, canonical} = project("part")
      File.chmod!(Path.join(root, ".minga.exs"), 0o666)
      File.chmod!(Path.join(root, ".minga"), 0o777)

      assert {:ok, sources} = Sources.admit(root)
      config = Path.join(canonical, ".minga.exs")
      folder = Path.join(canonical, ".minga")

      assert {:refused, _path, {:writable_by_others, ^config}} = sources.config
      assert {:refused, _path, {:writable_by_others, ^folder}} = sources.mcp
      assert {:refused, _path, {:writable_by_others, ^folder}} = sources.plugins
    end
  end

  describe "process/5" do
    test "gives the examined program and the project root as the working directory" do
      {root, canonical} = project("process")
      File.mkdir_p!(Path.join(root, "scripts"))
      File.write!(Path.join(root, "scripts/serve.sh"), "#!/bin/sh\n")
      {:ok, sources} = Sources.admit(root)

      assert Sources.process(sources, "scripts/serve.sh", ["--port", "0"], %{"A" => "b"}) ==
               {:ok,
                %{
                  executable: Path.join(canonical, "scripts/serve.sh"),
                  args: ["--port", "0"],
                  env: %{"A" => "b"},
                  cwd: canonical
                }}
    end

    test "a program that fails the rule is refused" do
      {root, canonical} = project("process_refused")
      {:ok, sources} = Sources.admit(root)

      # The refusal names the first thing on the way that is not there.
      assert Sources.process(sources, "scripts/gone.sh", [], %{}) ==
               {:error, {:unreadable, Path.join(canonical, "scripts"), :enoent}}

      # A bare name is the user's environment. It is found when the process starts, in the project root.
      assert Sources.process(sources, "tool", [], %{}) ==
               {:ok, %{executable: "tool", args: [], env: %{}, cwd: canonical}}
    end
  end
end
