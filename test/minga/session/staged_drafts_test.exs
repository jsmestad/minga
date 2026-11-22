defmodule Minga.Session.StagedDraftsTest do
  use ExUnit.Case, async: true

  alias Minga.Session.StagedDraft
  alias Minga.Session.StagedDrafts

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{opts: [staged_drafts_dir: Path.join(dir, "store")], root: Path.join(dir, "project")}
  end

  defp load!(root, opts) do
    {:ok, views} = StagedDrafts.load(root, opts)
    views
  end

  defp drafts(views) do
    for %{entries: entries} <- views, {:ok, _file, draft} <- entries, do: draft
  end

  describe "round trip" do
    test "a written draft loads back with its base and content bytes", %{opts: opts, root: root} do
      edit = StagedDraft.new("lib/a.ex", <<0, 255, "old\n">>, "new\n")
      created = StagedDraft.new("lib/new.ex", nil, "fresh")
      deleted = StagedDraft.new("gone.txt", "bye", :deleted)

      for draft <- [edit, created, deleted],
          do: :ok = StagedDrafts.write(root, "v1", 3, draft, opts)

      assert [%{view_id: "v1", workspace_id: 3}] = views = load!(root, opts)

      assert views |> drafts() |> Enum.sort_by(& &1.path) ==
               Enum.sort_by([edit, created, deleted], & &1.path)
    end

    test "names that are not valid UTF-8 round trip", %{opts: opts, root: root} do
      root = root <> <<0xFF>>
      draft = StagedDraft.new(<<"lib/", 0xFE, ".ex">>, "a", "b")

      assert StagedDrafts.write(root, <<0xFD>>, 1, draft, opts) == :ok
      assert [%{view_id: <<0xFD>>, entries: [{:ok, _, ^draft}]}] = load!(root, opts)
    end

    test "drafts are grouped by view and kept apart per project", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v1", 1, StagedDraft.new("a", "x", "y"), opts)
      :ok = StagedDrafts.write(root, "v2", 1, StagedDraft.new("b", "x", "y"), opts)
      :ok = StagedDrafts.write(root <> "-other", "v3", 1, StagedDraft.new("c", "x", "y"), opts)

      assert root |> load!(opts) |> Enum.map(&{&1.view_id, &1.workspace_id}) |> Enum.sort() ==
               [{"v1", 1}, {"v2", 1}]
    end

    test "rewriting a path replaces its draft", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "x", "first"), opts)
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "x", "second"), opts)

      assert [%{content: "second"}] = root |> load!(opts) |> drafts()
    end

    test "a draft above the size limit is refused, not written", %{opts: opts, root: root} do
      big = :binary.copy("x", StagedDrafts.max_file_bytes() + 1)

      assert StagedDrafts.write(root, "v", 1, StagedDraft.new("a", nil, big), opts) ==
               {:error, :draft_too_large}

      assert load!(root, opts) == []
    end
  end

  describe "privacy" do
    test "draft files are private: 0700 directories and 0600 files", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("secret.txt", "a", "b"), opts)
      file = StagedDrafts.draft_file(root, "v", "secret.txt", opts)

      assert mode(file) == 0o600
      assert mode(Path.dirname(file)) == 0o700
      assert mode(Path.dirname(Path.dirname(file))) == 0o700
      assert mode(StagedDrafts.dir(opts)) == 0o700
      refute file =~ "secret"
    end

    test "a symlinked store directory is refused for writing and loading",
         %{opts: opts, root: root, tmp_dir: dir} do
      elsewhere = Path.join(dir, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.ln_s!(elsewhere, StagedDrafts.dir(opts))

      assert {:error, {:insecure_directory, _, :symlink}} =
               StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "x", "y"), opts)

      assert File.ls!(elsewhere) == []
      assert {:error, {:insecure_directory, _, :symlink}} = StagedDrafts.load(root, opts)
    end

    test "a symlinked view directory is refused", %{opts: opts, root: root, tmp_dir: dir} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "x", "y"), opts)
      view_dir = StagedDrafts.view_dir(root, "v", opts)
      File.rename!(view_dir, Path.join(dir, "moved"))
      File.ln_s!(Path.join(dir, "moved"), view_dir)

      assert {:error, {:insecure_directory, _, :symlink}} = StagedDrafts.load(root, opts)
    end

    test "a directory owned by someone else is refused", %{opts: opts, root: root} do
      opts = Keyword.put(opts, :owner_uid, 4_000_000_000)

      assert {:error, {:insecure_directory, _, :owner}} =
               StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "x", "y"), opts)
    end
  end

  describe "deletion" do
    test "prune keeps only the named paths", %{opts: opts, root: root} do
      for path <- ~w(a b c),
          do: :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new(path, "", "x"), opts)

      :ok = StagedDrafts.prune(root, "v", ["b"], opts)

      assert [%{path: "b"}] = root |> load!(opts) |> drafts()
    end

    test "deleting a view removes all its drafts", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "", "x"), opts)
      :ok = StagedDrafts.delete_view(root, "v", opts)

      assert load!(root, opts) == []
      assert StagedDrafts.delete_view(root, "v", opts) == :ok
    end
  end

  describe "a draft that can never be restored is reported as lost" do
    test "by path when the file still names it", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("lib/a.ex", "base", "x"), opts)
      file = StagedDrafts.draft_file(root, "v", "lib/a.ex", opts)
      tampered = file |> File.read!() |> JSON.decode!() |> Map.put("base", Base.encode64("other"))
      File.write!(file, JSON.encode!(tampered))

      assert [%{entries: [{:lost, ^file, "lib/a.ex", :base_fingerprint_mismatch}]}] =
               load!(root, opts)
    end

    test "by version when a newer format wrote it", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "base", "x"), opts)
      file = StagedDrafts.draft_file(root, "v", "a", opts)

      File.write!(
        file,
        file |> File.read!() |> JSON.decode!() |> Map.put("version", 99) |> JSON.encode!()
      )

      assert [%{entries: [{:lost, ^file, "a", {:unsupported_version, 99}}]}] = load!(root, opts)
    end

    test "by file name when the file is not a draft", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "base", "x"), opts)
      file = StagedDrafts.draft_file(root, "v", "a", opts)
      File.write!(file, "not json")
      name = Path.basename(file)

      assert [%{entries: [{:lost, ^file, ^name, :invalid_format}]}] = load!(root, opts)
    end

    test "unless the path escapes the project", %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("../outside", "base", "x"), opts)

      assert [%{entries: [{:lost, _file, "../outside", :invalid_path}]}] = load!(root, opts)
    end
  end

  test "a draft that cannot be read now is retained, not lost", %{opts: opts, root: root} do
    :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "base", "x"), opts)
    file = StagedDrafts.draft_file(root, "v", "a", opts)
    File.chmod!(file, 0o000)

    assert [%{entries: [{:retained, ^file, _name, {:read_failed, :eacces}}]}] = load!(root, opts)
    assert File.exists?(file)
  end

  describe "temporary files" do
    test "loading leaves the temporary file of a write in progress alone",
         %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "base", "x"), opts)
      # Another writer is between writing its temporary file and renaming it.
      tmp = StagedDrafts.draft_file(root, "v", "b", opts) <> ".7.tmp"
      File.write!(tmp, "in flight")

      assert [%{path: "a"}] = root |> load!(opts) |> drafts()
      assert File.read!(tmp) == "in flight"
    end

    test "the view's owner removes leftover temporary files when it prunes",
         %{opts: opts, root: root} do
      :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "base", "x"), opts)
      tmp = StagedDrafts.draft_file(root, "v", "b", opts) <> ".7.tmp"
      File.write!(tmp, "left over")

      :ok = StagedDrafts.prune(root, "v", ["a"], opts)

      refute File.exists?(tmp)
      assert [%{path: "a"}] = root |> load!(opts) |> drafts()
    end
  end

  test "deleting a view leaves the project directory another writer may be using",
       %{opts: opts, root: root} do
    :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "base", "x"), opts)
    project_dir = Path.dirname(StagedDrafts.view_dir(root, "v", opts))

    :ok = StagedDrafts.delete_view(root, "v", opts)

    assert File.dir?(project_dir)
    assert :ok = StagedDrafts.write(root, "w", 1, StagedDraft.new("b", "base", "x"), opts)
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
