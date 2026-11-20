defmodule Minga.TestConfigIsolationTest do
  # Independent BEAM OS processes are serialized to avoid erl_child_setup EPIPE races.
  use ExUnit.Case, async: false

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.Tool.Output.Reference

  @moduletag :tmp_dir
  @moduletag timeout: 30_000
  @config_file Path.expand("../../config/test.exs", __DIR__)
  @child_script """
  [config_file, home, inherited_root] = System.argv()
  System.put_env("HOME", home)

  for {env, dir} <- [
        {"XDG_CONFIG_HOME", "config"},
        {"XDG_DATA_HOME", "data"},
        {"XDG_CACHE_HOME", "cache"},
        {"XDG_STATE_HOME", "state"}
      ] do
    System.put_env(env, Path.join(inherited_root, dir))
  end

  Config.Reader.read!(config_file)

  Enum.each(
    ~w(HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME),
    &IO.puts(System.fetch_env!(&1))
  )
  """

  test "a fresh BEAM never adopts an older config root with unaccounted namespaces", %{
    tmp_dir: root
  } do
    home = Path.join(root, "installed-home")
    inherited = Path.join(root, "inherited-xdg")
    File.mkdir!(home)
    File.mkdir!(inherited)

    first_home = allocate_config_home!(root, home, inherited)
    artifact_root = Path.join([first_home, "minga", "agent", "artifacts"])
    namespace = Reference.namespace("orphaned-test-fixture")
    orphan = Path.join([artifact_root, "namespaces", namespace, "owned.blob"])
    File.mkdir_p!(Path.dirname(orphan))
    File.write!(orphan, "owned fixture bytes")

    second_home = allocate_config_home!(root, home, inherited)
    assert first_home != second_home
    assert File.dir?(Path.join(second_home, "minga"))
    refute File.exists?(Path.join([second_home, "minga", "agent", "artifacts"]))
    assert File.ls!(home) == []
    assert File.ls!(inherited) == []

    quota = start_supervised!({ArtifactQuota, root: artifact_root})

    assert {:error, :missing_artifact_quota_ledger} =
             ArtifactQuota.namespace_registered?(quota, artifact_root, namespace)

    refute File.exists?(Path.join(artifact_root, "artifact_quota.sqlite3"))
    assert File.read!(orphan) == "owned fixture bytes"
  end

  @spec allocate_config_home!(String.t(), String.t(), String.t()) :: String.t()
  defp allocate_config_home!(root, home, inherited) do
    {output, 0} =
      System.cmd(
        "elixir",
        ["--erl", "+S 1:1", "-e", @child_script, "--", @config_file, home, inherited],
        env: [{"TMPDIR", root}],
        stderr_to_stdout: true
      )

    assert [^home, config, data, cache, state] = String.split(output, "\n", trim: true)
    profile = Path.dirname(config)
    dirs = [config, data, cache, state]

    assert profile != inherited
    assert Path.dirname(profile) == root
    assert dirs == Enum.map(~w(config data cache state), &Path.join(profile, &1))
    assert Enum.all?(dirs, &File.dir?/1)

    config
  end
end
