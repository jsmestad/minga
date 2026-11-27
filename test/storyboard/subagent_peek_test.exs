defmodule Minga.Storyboard.SubagentPeekTest do
  use ExUnit.Case, async: true

  alias Minga.Test.Storyboard.Check
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
end
