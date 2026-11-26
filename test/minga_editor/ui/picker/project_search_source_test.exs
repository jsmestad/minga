defmodule MingaEditor.UI.Picker.ProjectSearchSourceTest do
  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Buffer
  alias Minga.Project
  alias Minga.Project.Root

  alias MingaEditor.State.Search
  alias MingaEditor.State.FileTree
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectSearchSource

  # Minimal Context carrying only the field the source reads (the stashed query).
  defp ctx(query) do
    struct!(Context,
      buffers: %{active: nil},
      editing: nil,
      search: %Search{project_query: query},
      viewport: nil,
      tab_bar: nil,
      picker_ui: %{},
      capabilities: %{},
      theme: nil
    )
  end

  describe "async?/0" do
    test "the project search source runs off the editor input path" do
      assert ProjectSearchSource.async?()
    end
  end

  describe "async_fetch/1" do
    test "returns no items and no status when there is no pending query" do
      assert {:ok, [], %{}} = ProjectSearchSource.async_fetch(ctx(nil))
      assert {:ok, [], %{}} = ProjectSearchSource.async_fetch(ctx(""))
    end

    test "does not use the file tree as permission to search a directory" do
      project =
        start_supervised!(
          {Project,
           name: :"picker_search_#{System.unique_integer([:positive])}",
           subscribe: false,
           command_frecency: %{}}
        )

      context = %{
        ctx("needle")
        | project_server: project,
          file_tree: %FileTree{original_root: System.user_home!()}
      }

      assert {:error, "Open a directory workspace to search its files"} =
               ProjectSearchSource.async_fetch(context)
    end

    @tag :tmp_dir
    test "a widening row runs against the authorized root that produced it", %{tmp_dir: dir} do
      {:ok, root} = Root.directory(dir)
      match = %{file: ".chosen", line: 2, col: 3, text: "needle"}
      :ok = Minga.Test.ProjectSearchStub.set_results(dir, [match], :all)

      empty =
        ProjectSearchSource.empty(%{
          query: "",
          total: 0,
          context: %{project_query: "needle", project_search: {root, :visible}}
        })

      row = Enum.find(empty.rows, &(&1.label == "Search all files"))
      state = ProjectSearchSource.on_select(row, base_state(content: "scratch"))
      expected = %{match | file: Path.join(root.path, ".chosen")}

      assert {:ok, [%Item{id: ^expected}], %{project_search: {^root, :all}}} =
               ProjectSearchSource.async_fetch(Context.from_editor_state(state))
    end
  end

  describe "candidates/1" do
    test "is a thin wrapper over async_fetch and returns [] on missing query" do
      assert ProjectSearchSource.candidates(ctx(nil)) == []
    end
  end

  describe "on_select/2" do
    test "ignores items whose id is not a match map" do
      state = %{ignored: true}
      assert ProjectSearchSource.on_select(%Item{id: 0, label: "x"}, state) == state
    end

    test "opens a real match and moves to the selected cursor" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "project-search-source-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "first\nsecond\n")
      on_exit(fn -> File.rm(path) end)

      item = %Item{id: %{file: path, line: 2, col: 1}, label: "match"}
      state = ProjectSearchSource.on_select(item, base_state(content: "scratch"))
      pid = state.workspace.buffers.active

      assert Buffer.file_path(pid) == path
      assert Buffer.cursor(pid) == {1, 1}
    end
  end
end
