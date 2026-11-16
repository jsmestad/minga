defmodule MingaAgent.Changeset.ExecutableMutationTest do
  # Executes real shell scripts with System.cmd/2, which cannot run concurrently with async tests.
  use ExUnit.Case, async: false

  alias Minga.Buffer.FileMutation
  alias MingaAgent.Changeset
  alias MingaAgent.Changeset.Server

  @moduletag :tmp_dir
  @moduletag timeout: 30_000

  setup %{tmp_dir: root} do
    File.write!(Path.join(root, "file.txt"), "one two three\n")
    cs = start_supervised!({Server, project_root: root})
    %{cs: cs, root: root}
  end

  test "conditional commits preserve executable permissions in the command-visible overlay", %{
    cs: cs,
    root: root
  } do
    path = Path.join(root, "run.sh")
    original = "#!/bin/sh\nprintf original"
    draft = "#!/bin/sh\nprintf agent"
    File.write!(path, original)
    File.chmod!(path, 0o755)
    identity = {:changeset, path}
    {:ok, ^original, version} = Changeset.read_file_with_version(cs, "run.sh")
    expected = FileMutation.revision(original, version, identity)
    assert :ok = Changeset.conditional_mutate(cs, "run.sh", expected, {:replace, draft}, identity)
    target = Path.join(Changeset.overlay_path(cs), "run.sh")
    assert Bitwise.band(File.stat!(target).mode, 0o7777) == 0o755
    assert System.cmd(target, []) == {"agent", 0}
    assert File.read!(path) == original

    File.chmod!(target, 0o700)
    {:ok, ^draft, next} = Changeset.read_file_with_version(cs, "run.sh")
    expected = FileMutation.revision(draft, next, identity)
    final = "#!/bin/sh\nprintf final"
    assert :ok = Changeset.conditional_mutate(cs, "run.sh", expected, {:replace, final}, identity)
    assert Bitwise.band(File.stat!(target).mode, 0o7777) == 0o700
    assert System.cmd(target, []) == {"final", 0}
    assert :ok = Changeset.merge(cs)
    assert File.read!(path) == final
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o755
  end
end
