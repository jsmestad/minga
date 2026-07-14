defmodule MingaEditor.Window.ContentTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Window
  alias MingaEditor.Window.Content

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

  describe "Content.agent_chat/0" do
    test "creates a semantic agent chat content reference" do
      content = Content.agent_chat()
      assert content == {:agent_chat, :semantic}
    end
  end

  describe "Content.pid/1" do
    test "returns pid for buffer content" do
      pid = self()
      assert Content.pid({:buffer, pid}) == pid
    end

    test "returns nil for semantic agent chat content" do
      assert Content.pid({:agent_chat, :semantic}) == nil
    end
  end

  describe "Content.buffer_pid/1 with agent_chat" do
    test "returns nil for agent chat content" do
      assert Content.buffer_pid({:agent_chat, :semantic}) == nil
    end
  end

  describe "Content.buffer?/1 with agent_chat" do
    test "returns false for agent chat content" do
      assert Content.buffer?({:agent_chat, :semantic}) == false
    end
  end

  describe "Content.agent_chat?/1" do
    test "returns true for agent chat content" do
      assert Content.agent_chat?({:agent_chat, :semantic}) == true
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
      assert Content.editable?({:agent_chat, :semantic}) == false
    end
  end

  describe "Window content identity" do
    test "new/4 stores the buffer only in content" do
      pid = self()
      window = Window.new(1, pid, 24, 80)
      assert window.content == {:buffer, pid}
      refute Map.has_key?(window, :buffer)
    end

    test "new/5 stores the buffer only in content" do
      pid = self()
      window = Window.new(1, pid, 24, 80, {5, 10})
      assert window.content == {:buffer, pid}
      refute Map.has_key?(window, :buffer)
      assert window.cursor == {5, 10}
    end

    test "new_agent_chat/3 stores semantic agent chat content without a buffer field" do
      window = Window.new_agent_chat(1, 24, 80)
      assert window.content == {:agent_chat, :semantic}
      refute Map.has_key?(window, :buffer)
      assert Content.agent_chat?(window.content)
      refute Content.buffer?(window.content)
    end
  end
end
