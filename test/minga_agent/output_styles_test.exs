defmodule MingaAgent.OutputStylesTest do
  use ExUnit.Case, async: true

  alias MingaAgent.OutputStyle
  alias MingaAgent.OutputStyles

  @moduletag :tmp_dir

  describe "discover/2" do
    test "discovers global and project styles by filename stem", %{tmp_dir: dir} do
      global_dir = Path.join(dir, "global")
      project_dir = Path.join([dir, "project", ".minga", "output-styles"])
      File.mkdir_p!(global_dir)
      File.mkdir_p!(project_dir)
      File.write!(Path.join(global_dir, "concise.md"), "Be concise.\n")
      File.write!(Path.join(project_dir, "review.md"), "Review carefully.\n")

      styles = OutputStyles.discover(Path.join(dir, "project"), global_dir: global_dir)

      assert Enum.map(styles, & &1.name) == ["concise", "review"]

      assert %OutputStyle{source: :global, body: "Be concise."} =
               Enum.find(styles, &(&1.name == "concise"))

      assert %OutputStyle{source: :project, body: "Review carefully."} =
               Enum.find(styles, &(&1.name == "review"))
    end

    test "project styles override global styles with the same name", %{tmp_dir: dir} do
      global_dir = Path.join(dir, "global")
      project_dir = Path.join([dir, "project", ".minga", "output-styles"])
      File.mkdir_p!(global_dir)
      File.mkdir_p!(project_dir)
      File.write!(Path.join(global_dir, "concise.md"), "Global body")
      File.write!(Path.join(project_dir, "concise.md"), "Project body")

      assert [%OutputStyle{name: "concise", source: :project, body: "Project body"}] =
               OutputStyles.discover(Path.join(dir, "project"), global_dir: global_dir)
    end

    test "skips directories and empty files", %{tmp_dir: dir} do
      global_dir = Path.join(dir, "global")
      File.mkdir_p!(Path.join(global_dir, "nested"))
      File.write!(Path.join(global_dir, "empty.md"), "  \n")
      File.write!(Path.join(global_dir, "usable.md"), "Use me")

      assert [%OutputStyle{name: "usable"}] = OutputStyles.discover(nil, global_dir: global_dir)
    end
  end

  describe "format_for_prompt/1" do
    test "formats selected style with a prompt header" do
      style = %OutputStyle{
        name: "concise",
        body: "Short answers.",
        path: "/tmp/concise.md",
        source: :global
      }

      assert OutputStyles.format_for_prompt(style) == "## Output Style: concise\n\nShort answers."
      assert OutputStyles.format_for_prompt(nil) == nil
    end
  end
end
