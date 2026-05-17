defmodule MingaEditor.UI.Picker.TodoSearchSourceTest do
  use ExUnit.Case, async: true

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
end
