defmodule Minga.Buffer.BufferChangedEventTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.Server
  alias Minga.Events
  alias Minga.Events.BufferChangedEvent

  setup do
    Events.subscribe(:buffer_changed)
    :ok
  end

  describe "insert_char broadcasts delta and source" do
    test "event carries insertion delta with :user source" do
      buf = start_supervised!({Server, content: "hello"})
      Server.move_to(buf, {0, 5})
      Server.insert_char(buf, "!")

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        delta: %EditDelta{inserted_text: "!"}
                      }}
    end
  end

  describe "insert_text broadcasts delta and source" do
    test "event carries insertion delta" do
      buf = start_supervised!({Server, content: ""})
      Server.insert_text(buf, "world")

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        delta: %EditDelta{inserted_text: "world"}
                      }}
    end
  end

  describe "apply_text_edit broadcasts delta with source" do
    test "default source is :user" do
      buf = start_supervised!({Server, content: "hello world"})
      Server.apply_text_edit(buf, 0, 0, 0, 5, "goodbye")

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        delta: %EditDelta{inserted_text: "goodbye"}
                      }}
    end

    test "custom source is propagated" do
      buf = start_supervised!({Server, content: "hello world"})
      Server.apply_text_edit(buf, 0, 0, 0, 5, "goodbye", {:lsp, :elixir_ls})

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: {:lsp, :elixir_ls},
                        delta: %EditDelta{inserted_text: "goodbye"}
                      }}
    end
  end

  describe "apply_text_edits broadcasts with nil delta (bulk op)" do
    test "batch edits send nil delta with source" do
      buf = start_supervised!({Server, content: "aaa\nbbb\nccc"})
      edits = [{{0, 0}, {0, 3}, "AAA"}, {{1, 0}, {1, 3}, "BBB"}]
      Server.apply_text_edits(buf, edits, {:lsp, :elixir_ls})

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: {:lsp, :elixir_ls},
                        delta: nil
                      }}
    end
  end

  describe "delete_before broadcasts delta" do
    test "backspace sends deletion delta" do
      buf = start_supervised!({Server, content: "ab"})
      Server.move_to(buf, {0, 2})
      Server.delete_before(buf)

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        delta: %EditDelta{inserted_text: ""}
                      }}
    end
  end

  describe "undo broadcasts nil delta" do
    test "undo sends nil delta for full sync" do
      buf = start_supervised!({Server, content: "original"})
      Server.insert_char(buf, "x")
      # Drain the insert event
      assert_receive {:minga_event, :buffer_changed, %BufferChangedEvent{delta: %EditDelta{}}}

      # Break coalescing so undo has something to pop
      Server.break_undo_coalescing(buf)

      Server.undo(buf)

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{buffer: ^buf, delta: nil}}
    end
  end

  describe "replace_content broadcasts nil delta with source" do
    test "replace_content sends nil delta" do
      buf = start_supervised!({Server, content: "old"})
      Server.replace_content(buf, "new", :lsp)

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: {:lsp, :unknown},
                        delta: nil
                      }}
    end
  end

  describe "find_and_replace broadcasts with agent source" do
    test "sends nil delta (bulk op)" do
      buf = start_supervised!({Server, content: "hello world"})
      {:ok, _msg} = Server.find_and_replace(buf, "hello", "goodbye")

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: {:agent, _, _},
                        delta: nil
                      }}

      assert Server.content(buf) == "goodbye world"
    end
  end

  describe "event includes version" do
    test "version is set on the event" do
      buf = start_supervised!({Server, content: ""})
      Server.insert_char(buf, "a")

      assert_receive {:minga_event, :buffer_changed, %BufferChangedEvent{version: version}}

      assert is_integer(version)
    end
  end
end
