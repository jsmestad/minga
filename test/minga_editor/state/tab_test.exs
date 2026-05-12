defmodule MingaEditor.State.TabTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.VimState

  describe "new_file/2" do
    test "creates a file tab with default label" do
      tab = Tab.new_file(1)
      assert tab.id == 1
      assert tab.kind == :file
      assert tab.label == ""
      assert Context.empty?(tab.context)
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
    test "stores a context snapshot as a typed struct" do
      editing = VimState.new()
      ctx = %{editing: editing, keymap_scope: :editor}
      tab = Tab.new_file(1) |> Tab.set_context(ctx)
      assert %Context{} = tab.context
      assert tab.context.editing == editing
      assert tab.context.keymap_scope == :editor
    end

    test "migrates legacy vim field into editing" do
      legacy_vim = VimState.new()
      tab = Tab.new_file(1) |> Tab.set_context(%{vim: legacy_vim})
      assert tab.context.editing == legacy_vim
    end

    test "honors encoded present fields during migration" do
      tab = Tab.new_file(1) |> Tab.set_context(%{"present_fields" => [], "editing" => nil})
      assert Context.empty?(tab.context)
    end

    test "drops malformed legacy fields instead of marking them present" do
      tab = Tab.new_file(1) |> Tab.set_context(%{editing: :insert})
      assert Context.empty?(tab.context)
    end

    test "drops invalid keymap scopes" do
      tab = Tab.new_file(1) |> Tab.set_context(%{keymap_scope: :unknown_scope})
      assert Context.empty?(tab.context)
    end

    test "ignores malformed present_fields on externally built structs" do
      context = %Context{present_fields: [:missing_field, "keymap_scope"], keymap_scope: :editor}
      assert Context.to_workspace_map(context) == %{keymap_scope: :editor}
    end

    test "drops malformed values from externally built structs" do
      context = %Context{present_fields: [:keymap_scope], keymap_scope: :unknown_scope}
      assert Context.empty?(context)
      assert Context.to_workspace_map(context) == %{}
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

  describe "set_attention/2" do
    test "sets the attention flag to true" do
      tab = Tab.new_agent(1) |> Tab.set_attention(true)
      assert tab.attention == true
    end

    test "clears the attention flag" do
      tab = Tab.new_agent(1) |> Tab.set_attention(true) |> Tab.set_attention(false)
      assert tab.attention == false
    end

    test "defaults to false" do
      assert Tab.new_agent(1).attention == false
    end
  end

  describe "scrub_buffer/2" do
    test "removes dead pid from context.buffers" do
      bs = %Buffers{list: [:dead, :live], active: :dead, active_index: 0}
      tab = Tab.new_file(1) |> Tab.set_context(%{buffers: bs})

      result = Tab.scrub_buffer(tab, :dead)

      assert result.context.buffers.list == [:live]
      assert result.context.buffers.active == :live
    end

    test "no-op when context is empty" do
      tab = Tab.new_file(1)
      result = Tab.scrub_buffer(tab, :some_pid)

      assert result == tab
    end

    test "no-op when context has no buffers key" do
      tab = Tab.new_file(1) |> Tab.set_context(%{editing: VimState.new()})
      result = Tab.scrub_buffer(tab, :some_pid)

      assert result == tab
    end
  end
end
