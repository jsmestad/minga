defmodule Minga.Storyboard.SubagentPeekTest do
  use ExUnit.Case, async: true

  alias Minga.Test.EditorCase
  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Session

  @tag :storyboard
  test "the displayed Started row opens the same child as stepping through its batch" do
    entry = Registry.fetch!("minga.subagent.peek")
    keyboard = Registry.drive(entry)
    model = Session.model(keyboard)
    Enum.each(entry.checks, fn check -> assert Check.run(check, model) == :ok end)
    assert Registry.classify(model) == entry.id
    Session.stop(keyboard)

    pointer = Session.start(entry.start)
    parent = Session.window_id(pointer)
    assert Registry.classify(Session.model(pointer)) == "minga.conversation"
    pointer = Enum.reduce(entry.click_reach, pointer, &Session.click(&2, &1))
    peek = Session.model(pointer).ui.subagent_peek.pane
    assert peek.title == "Editorial and Jargon Roaster"
    assert peek.window_id != parent

    pointer = Session.press(pointer, "za")
    assert Session.model(pointer).ui.subagent_peek.pane.brief_open?
    pointer = Session.press(pointer, "]]")
    assert %{index: 2, window_id: same_peek} = Session.model(pointer).ui.subagent_peek.pane
    assert same_peek == peek.window_id
    pointer = Session.press(pointer, "[[ q")
    assert Session.window_id(pointer) == parent
    assert Registry.classify(Session.model(pointer)) == "minga.conversation"
    Session.stop(pointer)
  end

  @tag :storyboard
  test "Tasks Inspect opens the selected second child and q restores the parent" do
    entry = Registry.fetch!("minga.tasks.child_selected")
    keyboard = Registry.drive(entry)
    model = Session.model(keyboard)
    assert Registry.classify(model) == entry.id
    Enum.each(entry.checks, fn check -> assert Check.run(check, model) == :ok end)

    keyboard |> Session.press("i") |> assert_second_child()
    Session.stop(keyboard)

    # Click a different row from the displayed selection, while the exact parent is in another tab.
    conversation = Keyword.put(entry.start[:conversation], :open?, false)
    pointer = Session.start(conversation: conversation)
    refute Model.open?(Session.model(pointer), :agent_chat)

    pointer
    |> Session.press("SPC a a")
    |> Session.click({:tasks_row, "Editorial and Jargon Roaster", "select"})
    |> Session.click({:tasks_row, "Fact-Check Auditor", "i"})
    |> assert_second_child()

    Session.stop(pointer)
  end

  defp assert_second_child(session) do
    EditorCase.wait_until(
      session.ctx,
      fn _state ->
        match?(%{pane: %{focused?: true}}, Session.model(session).ui.subagent_peek)
      end,
      max_attempts: 250,
      message: "expected drawer Inspect to focus a child beside its parent"
    )

    model = Session.model(session)
    assert Registry.classify(model) == "minga.subagent.peek"
    refute model.ui.tasks_drawer.visible?
    assert %{title: "Fact-Check Auditor", index: 2} = model.ui.subagent_peek.pane
    parent = model.ui.subagent_peek.parent_window_id

    closed = Session.press(session, "q")
    assert Session.window_id(closed) == parent
    assert Registry.classify(Session.model(closed)) == "minga.conversation"
  end
end
