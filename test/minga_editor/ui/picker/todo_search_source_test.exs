defmodule MingaEditor.UI.Picker.TodoSearchSourceTest do
  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effects.TodoSearch
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.TodoSearchSource

  describe "parse_output/1" do
    test "parses grep path, line, and match text" do
      output = "lib/example.ex:12:  # TODO ship it\nREADME.md:4:// FIXME docs\n"

      assert TodoSearchSource.parse_output(output) == [
               %{path: "lib/example.ex", line: 12, text: "  # TODO ship it"},
               %{path: "README.md", line: 4, text: "// FIXME docs"}
             ]
    end

    test "ignores malformed and non-positive line results" do
      output = "not grep output\nfile.ex:nope:# TODO bad\nfile.ex:0:# TODO bad\n"
      assert TodoSearchSource.parse_output(output) == []
    end
  end

  describe "build_candidates/2" do
    test "creates picker items with icon, path line label, and trimmed description" do
      [item] =
        TodoSearchSource.build_candidates(
          [%{path: "lib/example.ex", line: 3, text: "  # NOTE explain"}],
          File.cwd!()
        )

      assert item.label =~ "lib/example.ex:3"
      assert item.description == "# NOTE explain"
      assert item.icon_color != nil
      assert item.id.line == 3
      assert String.ends_with?(item.id.path, "lib/example.ex")
    end

    test "empty and error results produce no items" do
      assert TodoSearchSource.build_candidates({:ok, ""}, File.cwd!()) == []
      assert TodoSearchSource.build_candidates({:error, "grep failed"}, File.cwd!()) == []
    end
  end

  describe "scheduled search" do
    test "finds TODOs in a git repository" do
      root = temporary_root()
      File.mkdir_p!(Path.join(root, "lib"))
      file = Path.join(root, "lib/example.ex")
      File.write!(file, "# TODO ship it\n")
      {"", 0} = System.cmd("git", ["-C", root, "init", "-q"])
      {"", 0} = System.cmd("git", ["-C", root, "add", "."])

      assert {:ok, %TodoSearch.Result{items: [item]}} = TodoSearch.run(effect(root))
      assert item.description == "# TODO ship it"
    end

    test "falls back to grep outside a git repository" do
      root = temporary_root()
      file = Path.join(root, "example.ex")
      File.write!(file, "# FIXME outside git\n")

      assert {:ok, %TodoSearch.Result{items: [item]}} = TodoSearch.run(effect(root))
      assert item.description == "# FIXME outside git"
    end

    test "reports a command failure" do
      root =
        Path.join(System.tmp_dir!(), "minga-missing-todo-#{System.unique_integer([:positive])}")

      assert {:error, message} = TodoSearch.run(effect(root))
      assert message =~ "exited with status"
    end

    test "marks a result stale after the picker revision changes" do
      state = base_state(content: "scratch")
      {state, old_revision} = PickerUI.open_loading(state, TodoSearchSource)
      {state, _new_revision} = PickerUI.open_loading(state, TodoSearchSource)
      request = TodoSearch.request(System.tmp_dir!(), old_revision)

      result = %TodoSearch.Result{
        root: System.tmp_dir!(),
        revision: old_revision,
        items: [],
        candidates: [],
        meta: %{}
      }

      {new_state, outcome} = TodoSearch.apply(state, Outcome.completed(request, result))

      assert outcome.status == :stale
      assert new_state == state
    end
  end

  defp effect(root), do: %TodoSearch{root: root, revision: make_ref()}

  defp temporary_root do
    root = Path.join(System.tmp_dir!(), "minga-todo-effect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  describe "on_select/2" do
    test "switches to the matching buffer and moves to the requested line" do
      path =
        Path.join(System.tmp_dir!(), "minga-todo-search-#{System.unique_integer([:positive])}.ex")

      File.write!(path, "first\nsecond\nthird\n")
      on_exit(fn -> File.rm(path) end)

      state = base_state(content: "scratch")
      path_buffer = start_supervised!({BufferProcess, file_path: path})
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, path_buffer)
      state = MingaEditor.BufferActivation.activate(state, 0)

      item = %Item{id: %{path: path, line: 3}, label: "todo"}
      new_state = TodoSearchSource.on_select(item, state)

      assert EditorState.active_buffer(new_state) == 1
      assert BufferProcess.cursor(path_buffer) == {2, 0}
    end
  end
end
