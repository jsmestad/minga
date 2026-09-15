defmodule MingaEditor.UI.Picker.DirectorySourceTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.DirectorySource
  alias MingaEditor.UI.Picker.FilesystemCandidate
  alias MingaEditor.UI.Picker.FilesystemContext
  alias MingaEditor.UI.Picker.FilesystemQuery
  alias MingaEditor.UI.Picker.FindFileSession

  test "lists one directory level with parent and directories before files", %{tmp_dir: tmp_dir} do
    refute DirectorySource.gui_preview?()

    nested = Path.join(tmp_dir, "nested")
    File.mkdir!(nested)
    File.write!(Path.join(nested, "not-enumerated.txt"), "nested")
    File.write!(Path.join(tmp_dir, "alpha.ex"), "a")
    File.write!(Path.join(tmp_dir, "zeta.txt"), "z")
    File.write!(Path.join(tmp_dir, "space ü.txt"), "unicode")
    File.write!(Path.join(tmp_dir, ".hidden"), "hidden")

    query = query_for_directory(tmp_dir)
    assert {:ok, items, %{}} = DirectorySource.async_fetch(source_context(query))

    candidates = Enum.map(items, & &1.id)
    assert [%FilesystemCandidate{path: parent, kind: :directory} | listed] = candidates
    assert parent == Path.dirname(tmp_dir)

    assert Enum.map(listed, & &1.kind) == [:directory, :file, :file, :file]

    assert Enum.map(listed, &Path.basename(&1.path)) == [
             "nested",
             "alpha.ex",
             "space ü.txt",
             "zeta.txt"
           ]

    refute Enum.any?(listed, &String.ends_with?(&1.path, "not-enumerated.txt"))
    refute Enum.any?(listed, &String.ends_with?(&1.path, ".hidden"))
  end

  test "offers an exact absolute or Home-relative regular file through normal filtering", %{
    tmp_dir: tmp_dir
  } do
    home = Path.join(tmp_dir, "home")
    File.mkdir!(home)
    path = Path.join(home, "résumé file.txt")
    File.write!(path, "expected")
    session = FindFileSession.new(tmp_dir, home, nil)

    for text <- [path, "~/résumé file.txt"] do
      query = FilesystemQuery.parse(session, text)
      assert {:ok, items, %{}} = DirectorySource.async_fetch(source_context(query))

      picker =
        Picker.new(items)
        |> Picker.filter_with_match_query(query.text, FilesystemQuery.filter_text(query))

      assert %Picker.Item{id: %FilesystemCandidate{path: ^path, kind: :file}} =
               Picker.selected_item(picker)
    end
  end

  test "keeps hidden entries out of browsing but offers one exact hidden target", %{
    tmp_dir: tmp_dir
  } do
    hidden = Path.join(tmp_dir, ".secret")
    File.write!(hidden, "hidden")
    browsing = query_for_directory(tmp_dir)
    assert {:ok, browsing_items, %{}} = DirectorySource.async_fetch(source_context(browsing))
    refute Enum.any?(browsing_items, &match?(%FilesystemCandidate{path: ^hidden}, &1.id))

    exact = FilesystemQuery.parse(session(tmp_dir), hidden)
    assert {:ok, exact_items, %{}} = DirectorySource.async_fetch(source_context(exact))
    assert Enum.any?(exact_items, &match?(%FilesystemCandidate{path: ^hidden}, &1.id))
  end

  test "rebinds a loaded directory without I/O and rejects the old query identity", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "alpha.txt")
    File.write!(path, "alpha")
    first = query_for_directory(tmp_dir)
    assert {:ok, items, %{}} = DirectorySource.async_fetch(source_context(first))

    second = FilesystemQuery.parse(first.session, Path.join(tmp_dir, "alp"))
    rebound = DirectorySource.rebind(items, second)
    old_file = Enum.find(items, &match?(%FilesystemCandidate{path: ^path}, &1.id))
    new_file = Enum.find(rebound, &match?(%FilesystemCandidate{path: ^path}, &1.id))
    context = FilesystemContext.new(second)

    refute DirectorySource.current_candidate?(old_file.id, context)
    assert DirectorySource.current_candidate?(new_file.id, context)

    forged = %{new_file.id | parent_directory: Path.dirname(tmp_dir)}
    refute DirectorySource.current_candidate?(forged, context)
  end

  test "reports missing directories and unsupported named-user paths as errors", %{
    tmp_dir: tmp_dir
  } do
    session = FindFileSession.new(tmp_dir, tmp_dir, nil)
    missing = FilesystemQuery.parse(session, Path.join(tmp_dir, "missing") <> "/")
    unsupported = FilesystemQuery.parse(session, "~someone/file")

    assert {:error, missing_message} = DirectorySource.async_fetch(source_context(missing))
    assert missing_message =~ "does not exist"

    assert {:error, unsupported_message} =
             DirectorySource.async_fetch(source_context(unsupported))

    assert unsupported_message =~ "not supported"
  end

  test "reports an unreadable directory without turning it into an empty result", %{
    tmp_dir: tmp_dir
  } do
    unreadable = Path.join(tmp_dir, "unreadable")
    File.mkdir!(unreadable)
    File.chmod!(unreadable, 0o000)
    on_exit(fn -> File.chmod(unreadable, 0o700) end)
    query = FilesystemQuery.for_directory(session(tmp_dir), unreadable)

    assert {:error, message} = DirectorySource.async_fetch(source_context(query))
    assert message == "Directory is not readable: #{unreadable}"
  end

  @spec query_for_directory(String.t()) :: FilesystemQuery.t()
  defp query_for_directory(directory) do
    session = FindFileSession.new(directory, directory, nil)
    FilesystemQuery.for_directory(session, directory)
  end

  @spec session(String.t()) :: FindFileSession.t()
  defp session(directory), do: FindFileSession.new(directory, directory, nil)

  @spec source_context(FilesystemQuery.t()) :: map()
  defp source_context(query), do: %{picker_ui: %{context: FilesystemContext.new(query)}}
end
