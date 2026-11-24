defmodule MingaEditor.RenderModel.UI.FileTreeFiletypeOverrideTest do
  @moduledoc """
  A runtime filetype override reaches file-tree rows on the next frame (#3493).

  File-tree icons come from one filetype registry read per frame. This test proves that read is not retained across frames: registering and removing an override changes the next frame's icons.
  """

  # Registers runtime overrides in the global Language.Registry ETS.
  use ExUnit.Case, async: false

  alias Minga.Language.Devicon
  alias Minga.Language.Registry
  alias Minga.Project.FileTree
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.FileTreeBuilder
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State.FileTree, as: FileTreeState

  @moduletag :tmp_dir

  setup do
    on_exit(fn -> Registry.register_override(".minga_bench_ext", nil) end)
  end

  test "registering and removing an extension override changes the next frame's icon", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "notes.minga_bench_ext"), "")
    ctx = context(dir)

    assert icon(ctx) == Devicon.icon(:text)

    Registry.register_override(".minga_bench_ext", :elixir)
    assert icon(ctx) == Devicon.icon(:elixir)

    Registry.register_override(".minga_bench_ext", nil)
    assert icon(ctx) == Devicon.icon(:text)
  end

  defp icon(ctx) do
    [row] = FileTreeBuilder.build(ctx).rows
    row.icon
  end

  defp context(dir) do
    tree = dir |> FileTree.new() |> FileTree.ensure_entries()
    file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)
    ctx = TestHelpers.base_state(port_manager: nil) |> Context.from_editor_state()
    workspace = %{ctx.workspace | file_tree: file_tree}
    %{ctx | workspace: workspace, intent: %{ctx.intent | workspace: workspace}}
  end
end
