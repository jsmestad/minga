defmodule MingaAgent.Tools.WorkspaceEditApplierTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.LSP.WorkspaceEdit
  alias MingaAgent.ProjectView
  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tools.WorkspaceEditApplier

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    outside = Path.join(dir, "outside")
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(outside)
    {:ok, view} = ProjectView.overlay(project)
    on_exit(fn -> ProjectView.close(view) end)
    context = ToolContext.new(project_root: project, project_view: view)
    %{project: project, outside: outside, view: view, context: context}
  end

  test "an absolute URI outside the project refuses the whole edit and changes nothing", %{
    project: project,
    outside: outside,
    view: view,
    context: context
  } do
    inside_path = write!(Path.join(project, "lib/inside.ex"), "old_name\n")
    outside_path = write!(Path.join(outside, "victim.ex"), "old_name\n")

    assert {0, 0, errors} = apply_edit(context, [inside_path, outside_path])

    assert Enum.any?(errors, &(&1 =~ "no files were changed"))
    assert Enum.any?(errors, &(&1 =~ "#{outside_path}: outside the project root"))
    refute Enum.any?(errors, &(&1 =~ inside_path))
    assert File.read!(outside_path) == "old_name\n"
    assert {:ok, "old_name\n"} = ProjectView.read_file(view, "lib/inside.ex")
    assert {:ok, []} = ProjectView.diff(view)
  end

  test "a URI through a symlink that escapes the project is refused and nothing outside is written",
       %{project: project, outside: outside, view: view, context: context} do
    victim = write!(Path.join(outside, "victim.ex"), "old_name\n")
    File.ln_s!(outside, Path.join(project, "vendor"))
    linked_path = Path.join(project, "vendor/victim.ex")

    assert {0, 0, errors} = apply_edit(context, [linked_path])

    assert Enum.any?(errors, &(&1 =~ "#{linked_path}: outside the project root"))
    assert File.read!(victim) == "old_name\n"
    assert {:ok, []} = ProjectView.diff(view)
  end

  test "in-project edits change open buffers and route closed files through the project view",
       %{project: project, view: view, context: context} do
    open_path = write!(Path.join(project, "lib/open.ex"), "old_name\n")
    buffer = start_supervised!({BufferProcess, file_path: open_path, content: "old_name\n"})
    real_path = write!(Path.join(project, "lib/real.ex"), "old_name\n")
    File.ln_s!("real.ex", Path.join(project, "lib/link.ex"))
    linked_path = Path.join(project, "lib/link.ex")

    assert {2, 2, []} = apply_edit(context, [open_path, linked_path])

    assert Buffer.content(buffer) == "new_name\n"
    assert {:ok, "new_name\n"} = ProjectView.read_file(view, "lib/real.ex")
    assert File.read!(real_path) == "old_name\n"
  end

  test "a closed-file edit is staged in an overlay view and reaches disk only when published", %{
    project: project,
    view: view,
    context: context
  } do
    path = write!(Path.join(project, "lib/closed.ex"), "old_name\n")

    assert {1, 1, []} = apply_edit(context, [path])

    assert File.read!(path) == "old_name\n"
    assert {:ok, "new_name\n"} = ProjectView.read_file(view, "lib/closed.ex")
    assert {:ok, entries} = ProjectView.diff(view)
    assert Enum.any?(entries, &(&1.path == "lib/closed.ex"))

    assert :ok = ProjectView.promote(view, :project_root)
    assert File.read!(path) == "new_name\n"
  end

  test "a closed-file edit is refused when the view holds a draft the language server has not seen",
       %{project: project, view: view, context: context} do
    path = write!(Path.join(project, "lib/drafted.ex"), "old_name\n")
    {:ok, source} = ProjectView.resolve_source(view, "lib/drafted.ex")

    token =
      Minga.Buffer.FileMutation.revision("old_name\n", nil, {:project_view, source.source_id})

    assert {:ok, _receipt} =
             ProjectView.conditional_mutate(
               view,
               "lib/drafted.ex",
               token,
               {:replace, "draft_name\n"}
             )

    assert {0, 0, [error]} = apply_edit(context, [path])

    assert error =~ "differs from the disk content"
    assert {:ok, "draft_name\n"} = ProjectView.read_file(view, "lib/drafted.ex")
    assert File.read!(path) == "old_name\n"
  end

  @spec apply_edit(ToolContext.t(), [String.t()]) :: WorkspaceEditApplier.result()
  defp apply_edit(context, paths) do
    changes =
      Map.new(paths, fn path ->
        {"file://#{path}",
         [
           %{
             "range" => %{
               "start" => %{"line" => 0, "character" => 0},
               "end" => %{"line" => 0, "character" => 8}
             },
             "newText" => "new_name"
           }
         ]}
      end)

    {:ok, documents} = WorkspaceEdit.parse(%{"changes" => changes})
    WorkspaceEditApplier.apply(documents, self(), :utf16, context)
  end

  @spec write!(String.t(), String.t()) :: String.t()
  defp write!(path, content) do
    File.write!(path, content)
    path
  end
end
