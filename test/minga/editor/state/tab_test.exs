defmodule Minga.Editor.State.TabTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab

  describe "new_file/2" do
    test "creates a file tab with default label" do
      tab = Tab.new_file(1)
      assert tab.id == 1
      assert tab.kind == :file
      assert tab.label == ""
      assert tab.context == %{}
    end

    test "creates a file tab with a label" do
      tab = Tab.new_file(1, "main.ex")
      assert tab.label == "main.ex"
    end
  end

  describe "new_agent/2" do
    test "creates an agent tab with default label" do
      tab = Tab.new_agent(2)
      assert tab.id == 2
      assert tab.kind == :agent
      assert tab.label == "Agent"
    end

    test "creates an agent tab with custom label" do
      tab = Tab.new_agent(2, "Fix the bug")
      assert tab.label == "Fix the bug"
    end
  end

  describe "set_label/2" do
    test "updates the label" do
      tab = Tab.new_file(1, "old") |> Tab.set_label("new")
      assert tab.label == "new"
    end
  end

  describe "set_context/2" do
    test "stores a context snapshot" do
      ctx = %{mode: :insert, keymap_scope: :editor}
      tab = Tab.new_file(1) |> Tab.set_context(ctx)
      assert tab.context == ctx
    end
  end

  describe "file?/1 and agent?/1" do
    test "file tab is file, not agent" do
      tab = Tab.new_file(1)
      assert Tab.file?(tab)
      refute Tab.agent?(tab)
    end

    test "agent tab is agent, not file" do
      tab = Tab.new_agent(1)
      assert Tab.agent?(tab)
      refute Tab.file?(tab)
    end
  end
end
