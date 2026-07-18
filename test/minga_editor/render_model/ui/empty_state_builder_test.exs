defmodule MingaEditor.RenderModel.UI.EmptyStateBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.EmptyState
  alias MingaEditor.RenderModel.UI.EmptyStateBuilder
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.State.Launchpad
  alias MingaEditor.State.Windows

  defp ctx(launchpad, window \\ RenderWindow.new_empty_state(1, 24, 80)) do
    %MingaEditor.Frontend.Emit.Context{
      port_manager: nil,
      capabilities: nil,
      theme: nil,
      font_registry: nil,
      windows: %Windows{tree: {:leaf, 1}, map: %{1 => window}, active: 1, next_id: 2},
      layout: nil,
      shell: nil,
      launchpad: launchpad
    }
  end

  defp launchpad(opts) do
    defaults = [session_file_count: 0, crashed?: false, recents: []]
    Launchpad.new(Keyword.merge(defaults, opts))
  end

  defp section(model, id), do: Enum.find(model.sections, &(&1.id == id))

  test "hidden when the workspace has no launchpad" do
    assert %EmptyState{visible?: false} = EmptyStateBuilder.build(ctx(nil))
  end

  test "hidden when the active render window is agent chat" do
    agent_window = RenderWindow.new_agent_chat(1, 24, 80)

    assert %EmptyState{visible?: false} =
             EmptyStateBuilder.build(ctx(launchpad([]), agent_window))
  end

  test "returning user gets a resume card, recents, actions, and footer" do
    lp = launchpad(session_file_count: 4, recents: ["lib/a.ex", "docs/b.md"])
    model = EmptyStateBuilder.build(ctx(lp))

    assert model.visible?
    refute model.crashed?
    assert model.focused_id == "resume"

    assert [%{id: "resume", kind: :resume, label: "resume last session", jump_key: "r"}] =
             section(model, :session).items

    assert section(model, :session).title == "Session"
    assert Enum.at(section(model, :session).items, 0).detail == "4 files"

    recents = section(model, :recent).items
    assert Enum.map(recents, & &1.label) == ["a.ex", "b.md"]
    assert Enum.map(recents, & &1.detail) == ["lib", "docs"]
    assert Enum.map(recents, & &1.jump_key) == ["1", "2"]
    assert Enum.all?(recents, &(&1.icon != ""))

    start_ids = Enum.map(section(model, :start).items, & &1.id)
    assert "action-tutor" in start_ids

    assert [%{jump_key: "i"}, %{detail: ":q"}] = section(model, :footer).items
  end

  test "crashed session styles the resume card" do
    model = EmptyStateBuilder.build(ctx(launchpad(session_file_count: 2, crashed?: true)))

    assert model.crashed?
    assert section(model, :session).title == "Crashed session"
    assert [%{label: "restore session"}] = section(model, :session).items
  end

  test "first run shows a Get started tutor hero and no recents" do
    model = EmptyStateBuilder.build(ctx(launchpad([])))

    assert section(model, :session).title == "Get started"

    assert [%{id: "action-tutor", detail: ":Tutor", jump_key: "RET"}] =
             section(model, :session).items

    assert section(model, :recent) == nil
    refute "action-tutor" in Enum.map(section(model, :start).items, & &1.id)
  end

  test "action chords are resolved from the live keymap" do
    model = EmptyStateBuilder.build(ctx(launchpad([])))

    chords =
      section(model, :start).items
      |> Map.new(&{&1.id, &1.chord})

    assert chords["action-find-file"] == "SPC f f"
    assert chords["action-palette"] == "SPC :"
  end
end
