defmodule Minga.Extension.SourceSnapshotTest do
  # Creates a real FIFO with mkfifo to exercise descriptor-safe source admission.
  use ExUnit.Case, async: false

  alias Minga.Extension.SecureFile
  alias Minga.Extension.SourceSnapshot

  setup do
    root =
      Path.join(System.tmp_dir!(), "minga-source-snapshot-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "regular source bytes are copied privately and fingerprinted from the copy", %{root: root} do
    source = Path.join(root, "nested/source.ex")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "defmodule SnapshotRegular, do: :ok")

    assert {:ok, snapshot} = SourceSnapshot.create(root, [source])
    assert [copied] = snapshot.files
    assert File.read!(copied) == File.read!(source)
    assert File.stat!(snapshot.dir).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(copied).mode |> Bitwise.band(0o777) == 0o600
    assert byte_size(snapshot.fingerprint) == 32
    assert :ok = SourceSnapshot.cleanup(snapshot)
  end

  test "symlink and FIFO source entries are rejected without following or blocking", %{root: root} do
    target = Path.join(root, "target.ex")
    symlink = Path.join(root, "link.ex")
    fifo = Path.join(root, "pipe.ex")
    File.write!(target, "safe")
    File.ln_s!(target, symlink)
    {_output, 0} = System.cmd("mkfifo", [fifo], stderr_to_stdout: true)

    assert {:error, {:non_regular_file, ^symlink, :symlink}} = SecureFile.read(symlink, 100)
    assert {:error, {:non_regular_file, ^fifo, :other}} = SecureFile.read(fifo, 100)

    assert {:error, {:non_regular_file, ^symlink, :symlink}} =
             SourceSnapshot.create(root, [symlink])

    assert {:error, {:non_regular_file, ^fifo, :other}} = SourceSnapshot.create(root, [fifo])
  end

  test "descriptor size is enforced before bounded content is returned", %{root: root} do
    source = Path.join(root, "large.ex")
    File.write!(source, String.duplicate("x", 32))

    assert {:error, {:file_too_large, ^source, 32, 8}} = SecureFile.read(source, 8)
  end
end
