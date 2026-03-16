defmodule Minga.Editor.WindowPinnedTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Window

  describe "pinned field" do
    test "default window is not pinned" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new(1, buf, 10, 80)
      assert win.pinned == false
    end

    test "agent chat window is pinned by default" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new_agent_chat(1, buf, 10, 80)
      assert win.pinned == true
    end

    test "pinned can be set to false" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new_agent_chat(1, buf, 10, 80)
      win = %{win | pinned: false}
      assert win.pinned == false
    end
  end

  describe "scroll_viewport/3" do
    test "scrolls viewport down by delta" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new(1, buf, 10, 80)
      win = Window.scroll_viewport(win, 3, 100)
      assert win.viewport.top == 3
    end

    test "scrolls viewport up by negative delta" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new(1, buf, 10, 80)
      win = Window.scroll_viewport(win, 10, 100)
      win = Window.scroll_viewport(win, -3, 100)
      assert win.viewport.top == 7
    end

    test "clamps to 0 when scrolling up past top" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new(1, buf, 10, 80)
      win = Window.scroll_viewport(win, -5, 100)
      assert win.viewport.top == 0
    end

    test "clamps to max_top when scrolling past bottom" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new(1, buf, 10, 80)
      # With rows=10, reserved=2, content_rows=8. max_top = 100 - 8 = 92
      win = Window.scroll_viewport(win, 200, 100)
      assert win.viewport.top == 92
    end

    test "scroll up unpins" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new_agent_chat(1, buf, 10, 80)
      assert win.pinned == true

      win = Window.scroll_viewport(win, -3, 100)
      assert win.pinned == false
    end

    test "scroll down re-pins only when reaching bottom" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new(1, buf, 10, 80)

      # Scroll down but not to bottom
      win = Window.scroll_viewport(win, 5, 100)
      assert win.pinned == false

      # Scroll down to the very bottom (max_top = 92)
      win = Window.scroll_viewport(win, 200, 100)
      assert win.pinned == true
    end

    test "delta of 0 preserves current state" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      win = Window.new_agent_chat(1, buf, 10, 80)
      original_pinned = win.pinned
      original_top = win.viewport.top

      win = Window.scroll_viewport(win, 0, 100)
      assert win.pinned == original_pinned
      assert win.viewport.top == original_top
    end
  end
end
