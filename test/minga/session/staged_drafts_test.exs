defmodule Minga.Session.StagedDraftsTest do
  use ExUnit.Case, async: true

  alias Minga.Session.StagedDraft
  alias Minga.Session.StagedDrafts

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{opts: [staged_drafts_dir: Path.join(dir, "store")], root: Path.join(dir, "project")}
  end

  describe "round trip" do
    test "a written draft loads back with its base and content bytes", %{opts: opts, root: root} do
      edit = StagedDraft.new("lib/a.ex", <<0, 255, "old\n">>, "new\n")
      created = StagedDraft.new("lib/new.ex", nil, "fresh")
      deleted = StagedDraft.new("gone.txt", "bye", :deleted)

      for draft <- [edit, created, deleted], do: :ok = StagedDrafts.write(root, 3, draft, opts)

      assert [{3, entries}] = StagedDrafts.load(root, opts)

      assert entries |> Enum.map(fn {:ok, _file, draft} -> draft end) |> Enum.sort_by(& &1.path) ==
               Enum.sort_by([edit, created, deleted], & &1.path)
    end

    test "drafts are grouped by workspace and kept apart per project", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, 1, StagedDraft.new("a", "x", "y"), opts)
      :ok = StagedDrafts.write(root, 2, StagedDraft.new("b", "x", "y"), opts)
      :ok = StagedDrafts.write(root <> "-other", 1, StagedDraft.new("c", "x", "y"), opts)

      assert [{1, [{:ok, _, %{path: "a"}}]}, {2, [{:ok, _, %{path: "b"}}]}] =
               StagedDrafts.load(root, opts)
    end

    test "rewriting a path replaces its draft", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, 1, StagedDraft.new("a", "x", "first"), opts)
      :ok = StagedDrafts.write(root, 1, StagedDraft.new("a", "x", "second"), opts)

      assert [{1, [{:ok, _, %{content: "second"}}]}] = StagedDrafts.load(root, opts)
    end
  end

  test "draft files are private: 0700 directories and 0600 files", %{opts: opts, root: root} do
    :ok = StagedDrafts.write(root, 1, StagedDraft.new("secret.txt", "a", "b"), opts)
    file = StagedDrafts.draft_file(root, 1, "secret.txt", opts)

    assert mode(file) == 0o600
    assert mode(Path.dirname(file)) == 0o700
    assert mode(Path.dirname(Path.dirname(file))) == 0o700
    assert mode(StagedDrafts.dir(opts)) == 0o700
    refute file =~ "secret"
  end

  describe "deletion" do
    test "prune keeps only the named paths", %{opts: opts, root: root} do
      for path <- ~w(a b c),
          do: :ok = StagedDrafts.write(root, 1, StagedDraft.new(path, "", "x"), opts)

      :ok = StagedDrafts.prune(root, 1, ["b"], opts)

      assert [{1, [{:ok, _, %{path: "b"}}]}] = StagedDrafts.load(root, opts)
    end

    test "deleting a workspace removes all its drafts", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, 1, StagedDraft.new("a", "", "x"), opts)
      :ok = StagedDrafts.delete_workspace(root, 1, opts)

      assert StagedDrafts.load(root, opts) == []
      assert StagedDrafts.delete_workspace(root, 1, opts) == :ok
    end
  end

  describe "unreadable drafts are reported as lost" do
    test "by path when the file still names it", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, 1, StagedDraft.new("lib/a.ex", "base", "x"), opts)
      file = StagedDrafts.draft_file(root, 1, "lib/a.ex", opts)
      tampered = file |> File.read!() |> JSON.decode!() |> Map.put("base", Base.encode64("other"))
      File.write!(file, JSON.encode!(tampered))

      assert [{1, [{:lost, ^file, "lib/a.ex", :base_fingerprint_mismatch}]}] =
               StagedDrafts.load(root, opts)
    end

    test "by version when a newer format wrote it", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, 1, StagedDraft.new("a", "base", "x"), opts)
      file = StagedDrafts.draft_file(root, 1, "a", opts)

      File.write!(
        file,
        file |> File.read!() |> JSON.decode!() |> Map.put("version", 99) |> JSON.encode!()
      )

      assert [{1, [{:lost, ^file, "a", {:unsupported_version, 99}}]}] =
               StagedDrafts.load(root, opts)
    end

    test "by file name when the file is not a draft", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, 1, StagedDraft.new("a", "base", "x"), opts)
      file = StagedDrafts.draft_file(root, 1, "a", opts)
      File.write!(file, "not json")
      name = Path.basename(file)

      assert [{1, [{:lost, ^file, ^name, :invalid_format}]}] = StagedDrafts.load(root, opts)
    end

    test "unless the path escapes the project", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, 1, StagedDraft.new("../outside", "base", "x"), opts)

      assert [{1, [{:lost, _file, "../outside", :invalid_path}]}] = StagedDrafts.load(root, opts)
    end
  end

  test "leftover temporary files from an interrupted write are removed", %{opts: opts, root: root} do
    :ok = StagedDrafts.write(root, 1, StagedDraft.new("a", "base", "x"), opts)
    tmp = StagedDrafts.draft_file(root, 1, "a", opts) <> ".7.tmp"
    File.write!(tmp, "partial")

    assert [{1, [{:ok, _, %{path: "a"}}]}] = StagedDrafts.load(root, opts)
    refute File.exists?(tmp)
  end

  describe "base_changed?/2" do
    test "compares the file on disk with the staged base" do
      draft = StagedDraft.new("a", "base", "x")
      refute StagedDraft.base_changed?(draft, {:ok, "base"})
      assert StagedDraft.base_changed?(draft, {:ok, "edited"})
      assert StagedDraft.base_changed?(draft, {:error, :enoent})

      created = StagedDraft.new("a", nil, "x")
      refute StagedDraft.base_changed?(created, {:error, :enoent})
      assert StagedDraft.base_changed?(created, {:ok, "someone made it"})
    end
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
