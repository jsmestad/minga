defmodule MingaEditor.UI.Picker.TodoSearchSourceTest do
  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Buffer.Process, as: BufferProcess
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

  describe "on_select/2" do
    test "switches to the matching buffer and moves to the requested line" do
      path =
        Path.join(System.tmp_dir!(), "minga-todo-search-#{System.unique_integer([:positive])}.ex")

      File.write!(path, "first\nsecond\nthird\n")
      on_exit(fn -> File.rm(path) end)

      state = base_state(content: "scratch")
      path_buffer = start_supervised!({BufferProcess, file_path: path})
      state = EditorState.add_buffer(state, path_buffer)
      state = EditorState.switch_buffer(state, 0)

      item = %Item{id: %{path: path, line: 3}, label: "todo"}
      new_state = TodoSearchSource.on_select(item, state)

      assert EditorState.active_buffer(new_state) == 1
      assert BufferProcess.cursor(path_buffer) == {2, 0}
    end
  end
end
