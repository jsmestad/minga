defmodule Minga.Editor.Window.ContentTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content

  describe "Content.buffer/1" do
    test "creates a buffer content reference" do
      pid = self()
      content = Content.buffer(pid)
      assert content == {:buffer, pid}
    end
  end

  describe "Content.buffer_pid/1" do
    test "extracts pid from buffer content" do
      pid = self()
      content = Content.buffer(pid)
      assert Content.buffer_pid(content) == pid
    end
  end

  describe "Content.buffer?/1" do
    test "returns true for buffer content" do
      assert Content.buffer?({:buffer, self()}) == true
    end
  end

  describe "Content.agent_chat/1" do
    test "creates an agent chat content reference" do
      pid = self()
      content = Content.agent_chat(pid)
      assert content == {:agent_chat, pid}
    end
  end

  describe "Content.pid/1" do
    test "returns pid for buffer content" do
      pid = self()
      assert Content.pid({:buffer, pid}) == pid
    end

    test "returns pid for agent chat content" do
      pid = self()
      assert Content.pid({:agent_chat, pid}) == pid
    end
  end

  describe "Content.buffer_pid/1 with agent_chat" do
    test "returns nil for agent chat content" do
      assert Content.buffer_pid({:agent_chat, self()}) == nil
    end
  end

  describe "Content.buffer?/1 with agent_chat" do
    test "returns false for agent chat content" do
      assert Content.buffer?({:agent_chat, self()}) == false
    end
  end

  describe "Content.agent_chat?/1" do
    test "returns true for agent chat content" do
      assert Content.agent_chat?({:agent_chat, self()}) == true
    end

    test "returns false for buffer content" do
      assert Content.agent_chat?({:buffer, self()}) == false
    end
  end

  describe "Content.editable?/1" do
    test "buffer is editable" do
      assert Content.editable?({:buffer, self()}) == true
    end

    test "agent chat is not editable" do
      assert Content.editable?({:agent_chat, self()}) == false
    end
  end

  describe "Window.new sets content field" do
    test "new/4 sets both content and buffer" do
      pid = self()
      window = Window.new(1, pid, 24, 80)
      assert window.content == {:buffer, pid}
      assert window.buffer == pid
    end

    test "new/5 sets both content and buffer" do
      pid = self()
      window = Window.new(1, pid, 24, 80, {5, 10})
      assert window.content == {:buffer, pid}
      assert window.buffer == pid
      assert window.cursor == {5, 10}
    end

    test "new_agent_chat/4 sets agent chat content" do
      pid = self()
      window = Window.new_agent_chat(1, pid, 24, 80)
      assert window.content == {:agent_chat, pid}
      assert window.buffer == pid
      assert Content.agent_chat?(window.content)
      refute Content.buffer?(window.content)
    end
  end
end
