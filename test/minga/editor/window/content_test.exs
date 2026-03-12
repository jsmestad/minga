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
  end
end
