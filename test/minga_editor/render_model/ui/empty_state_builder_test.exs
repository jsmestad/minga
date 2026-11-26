defmodule MingaEditor.RenderModel.UI.EmptyStateBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.EmptyList
  alias Minga.RenderModel.UI.EmptyState
  alias MingaEditor.RenderModel.UI.EmptyStateBuilder
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Renderer.WindowCache
  alias MingaEditor.Window
  alias MingaEditor.State.Launchpad
  alias MingaEditor.State.Windows

  defp ctx(launchpad, window \\ render_window(Window.new_empty_state(1, 24, 80))) do
    input = Input.from_editor_state(TestHelpers.base_state())

    %Context{
      intent: input.intent,
      workspace: %{input.workspace | launchpad: launchpad},
      windows: %Windows{tree: {:leaf, 1}, map: %{1 => window}, active: 1, next_id: 2},
      layout: input.layout,
      font_registry: input.font_registry,
      message_store: input.message_store,
      title: "Minga"
    }
  end

  defp render_window(window) do
    RenderWindow.materialize(window.id, WindowIntent.from_window(window), WindowCache.reset())
  end

  defp home(opts) do
    defaults = [project_root: "/work/minga", place: :project, git: nil, recents: [], projects: []]
    Launchpad.new(Keyword.merge(defaults, opts))
  end

  defp section(model, id), do: Enum.find(model.sections, &(&1.id == id))

  test "hidden when the workspace has no home" do
    assert %EmptyState{visible?: false} = EmptyStateBuilder.build(ctx(nil))
  end

  test "hidden when the active render window is agent chat" do
    agent_window = render_window(Window.new_agent_chat(1, 24, 80))

    assert %EmptyState{visible?: false} = EmptyStateBuilder.build(ctx(home([]), agent_window))
  end

  test "a project home names the project, its git state and its recent files, numbered" do
    git = %{branch: "main", changed: 11}
    model = EmptyStateBuilder.build(ctx(home(git: git, recents: ["lib/a.ex", "README.md"])))

    assert model.visible?
    assert model.title == "minga"
    assert model.path == "/work/minga"
    assert model.status == "main · 11 changed"
    assert model.focused_id == "recent-1"

    recent = section(model, :recent)
    assert recent.title == "Recent in this project"
    assert Enum.map(recent.items, & &1.label) == ["a.ex", "README.md"]
    assert Enum.map(recent.items, & &1.detail) == ["lib", ""]
    assert Enum.map(recent.items, & &1.jump_key) == ["1", "2"]
  end

  test "the project's next actions carry their live leader keys" do
    model = EmptyStateBuilder.build(ctx(home([])))

    assert Enum.map(section(model, :next).items, &{&1.label, &1.chord}) == [
             {"Find a file", "SPC SPC"},
             {"New task", "SPC a n"},
             {"File tree", "SPC o p"},
             {"Switch project", "SPC p p"}
           ]
  end

  test "a project with nothing recent says so and focuses the first action" do
    model = EmptyStateBuilder.build(ctx(home([])))

    assert %{items: [], empty: "Nothing opened here yet."} = section(model, :recent)
    assert model.focused_id == "action-project_find_file"
  end

  test "a folder without markers says so and offers the file tree first" do
    model = EmptyStateBuilder.build(ctx(home(project_root: "/tmp/notes", place: :folder)))

    assert model.title == "notes"
    assert model.status =~ "Not a project"
    assert model.note == "Minga uses this folder as the root for now."
    assert section(model, :recent).title == "Recent in this folder"
    assert [%{label: "File tree"} | _] = section(model, :next).items
  end

  test "outside a project the home lists recent projects, numbered" do
    lp = home(project_root: nil, place: :outside, projects: ["/work/minga", "/work/notes"])
    model = EmptyStateBuilder.build(ctx(lp))

    assert model.title == "Minga"
    assert model.status == "No project here."
    assert section(model, :recent) == nil

    projects = section(model, :projects)

    assert Enum.map(projects.items, &{&1.jump_key, &1.label, &1.kind}) == [
             {"1", "minga", :project},
             {"2", "notes", :project}
           ]

    assert Enum.map(section(model, :next).items, & &1.label) == [
             "Switch project",
             "Find a file",
             "Add a project"
           ]
  end

  test "a recent project with unsaved text waiting says so on its row" do
    lp =
      home(project_root: nil, place: :outside, projects: ["/work/minga", "/work/notes"])
      |> Launchpad.mark_waiting([%{root: "/work/notes", files: 1}])

    projects = section(EmptyStateBuilder.build(ctx(lp)), :projects)

    assert Enum.map(projects.items, &{&1.label, &1.meta}) == [
             {"minga", ""},
             {"notes", "unsaved text to recover"}
           ]
  end

  test "no tasks section when Minga has no tasks" do
    assert section(EmptyStateBuilder.build(ctx(home([]))), :tasks) == nil
  end

  describe "empty_list/4" do
    test "builds the anatomy with each action's key from the live keymap and its command as the id" do
      list =
        EmptyStateBuilder.empty_list(
          "No projects yet.",
          "Minga remembers folders you open.",
          [{:project_add, "Add a folder"}, {:find_file, "Open a file"}]
        )

      assert %EmptyList{
               glyph: "",
               title: "No projects yet.",
               why: "Minga remembers folders you open.",
               selected: 0,
               actions: [
                 %EmptyList.Action{id: "project_add", key: "SPC p a", label: "Add a folder"},
                 %EmptyList.Action{id: "find_file", key: "SPC f f", label: "Open a file"}
               ]
             } = list
    end

    test "a surface's own bare key, a glyph and a preselected action are kept as given" do
      list =
        EmptyStateBuilder.empty_list(
          "Nothing to commit on main.",
          "Up to date.",
          [
            {:git_log, "Show log", "l"},
            {:project_add, "Add a folder"}
          ],
          glyph: "●",
          selected: 1
        )

      assert list.glyph == "●"
      assert list.selected == 1
      assert [%{id: "git_log", key: "l"}, %{key: "SPC p a"}] = list.actions
    end
  end
end
