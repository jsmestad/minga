defmodule Minga.TestConfigIsolationTest do
  # Independent BEAM OS processes are serialized to avoid erl_child_setup EPIPE races.
  use ExUnit.Case, async: false

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.Tool.Output.Reference

  @moduletag :tmp_dir
  @moduletag timeout: 30_000
  @config_file Path.expand("../../config/test.exs", __DIR__)
  @child_script """
  Config.Reader.read!(hd(System.argv()))
  IO.puts(System.fetch_env!("XDG_CONFIG_HOME"))
  """

  test "a fresh BEAM never adopts an older config root with unaccounted namespaces", %{
    tmp_dir: root
  } do
    first_home = allocate_config_home!(root)
    artifact_root = Path.join([first_home, "minga", "agent", "artifacts"])
    namespace = Reference.namespace("orphaned-test-fixture")
    orphan = Path.join([artifact_root, "namespaces", namespace, "owned.blob"])
    File.mkdir_p!(Path.dirname(orphan))
    File.write!(orphan, "owned fixture bytes")

    second_home = allocate_config_home!(root)
    assert first_home != second_home
    assert Path.dirname(first_home) == root
    assert Path.dirname(second_home) == root
    assert File.dir?(Path.join(second_home, "minga"))
    refute File.exists?(Path.join([second_home, "minga", "agent", "artifacts"]))

    quota = start_supervised!({ArtifactQuota, root: artifact_root})

    assert {:error, :missing_artifact_quota_ledger} =
             ArtifactQuota.namespace_registered?(quota, artifact_root, namespace)

    refute File.exists?(Path.join(artifact_root, "artifact_quota.sqlite3"))
    assert File.read!(orphan) == "owned fixture bytes"
  end

  @spec allocate_config_home!(String.t()) :: String.t()
  defp allocate_config_home!(root) do
    {output, 0} =
      System.cmd(
        "elixir",
        ["--erl", "+S 1:1", "-e", @child_script, "--", @config_file],
        env: [{"TMPDIR", root}],
        stderr_to_stdout: true
      )

    String.trim(output)
  end
end
