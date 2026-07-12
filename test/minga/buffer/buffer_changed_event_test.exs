defmodule Minga.Buffer.BufferChangedEventTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Events
  alias Minga.Events.BufferChangedEvent

  setup do
    Events.subscribe(:buffer_changed)
    :ok
  end

  describe "insert_char broadcasts delta and source" do
    test "event carries insertion delta with :user source" do
      buf = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.move_to(buf, {0, 5})
      BufferProcess.insert_char(buf, "!")

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        delta: %EditDelta{inserted_text: "!"},
                        sequence: 1
                      }}
    end
  end

  describe "insert_text broadcasts delta and source" do
    test "event carries insertion delta" do
      buf = start_supervised!({BufferProcess, content: ""})
      BufferProcess.insert_text(buf, "world")

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        delta: %EditDelta{inserted_text: "world"}
                      }}
    end
  end

  describe "apply_edit broadcasts delta with source" do
    test "default source is :user" do
      buf = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.apply_edit(buf, 0, 0, 0, 5, "goodbye")

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        delta: %EditDelta{inserted_text: "goodbye"}
                      }}
    end

    test "custom source is propagated" do
      buf = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.apply_edit(buf, 0, 0, 0, 5, "goodbye", EditSource.lsp(:elixir_ls))

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: {:lsp, :elixir_ls},
                        delta: %EditDelta{inserted_text: "goodbye"}
                      }}
    end
  end

  describe "apply_edits broadcasts with nil delta (bulk op)" do
    test "batch edits send nil delta with source" do
      buf = start_supervised!({BufferProcess, content: "aaa\nbbb\nccc"})
      edits = [{{0, 0}, {0, 3}, "AAA"}, {{1, 0}, {1, 3}, "BBB"}]
      BufferProcess.apply_edits(buf, edits, EditSource.lsp(:elixir_ls))

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
      buf = start_supervised!({BufferProcess, content: "ab"})
      BufferProcess.move_to(buf, {0, 2})
      BufferProcess.delete_before(buf)

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        delta: %EditDelta{inserted_text: ""}
                      }}
    end
  end

  describe "clear_line broadcasts delta" do
    test "clear_line sends a deletion delta, records it for consumers, and adjusts decorations" do
      buf = start_supervised!({BufferProcess, content: "one\ntwo\nthree"})

      _id =
        BufferProcess.add_virtual_text(buf, {1, 3},
          segments: [{" note", Face.new(fg: 0xFF0000)}],
          placement: :inline
        )

      assert {:ok, "two"} = BufferProcess.clear_line(buf, 1)

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        delta: %EditDelta{inserted_text: ""} = delta
                      }}

      assert delta.start_byte == 4
      assert delta.old_end_byte == 7
      assert delta.new_end_byte == 4
      assert delta.start_position == {1, 0}
      assert delta.old_end_position == {1, 3}
      assert delta.new_end_position == {1, 0}
      assert {:ok, [^delta]} = BufferProcess.consume_edit_deltas(buf, :lsp)

      assert [virtual_text] =
               buf
               |> BufferProcess.decorations()
               |> Decorations.virtual_texts_for_line(1)

      assert virtual_text.anchor == {1, 0}
    end
  end

  describe "undo broadcasts nil delta" do
    test "undo sends nil delta for full sync" do
      buf = start_supervised!({BufferProcess, content: "original"})
      BufferProcess.insert_char(buf, "x")
      # Drain the insert event
      assert_receive {:minga_event, :buffer_changed, %BufferChangedEvent{delta: %EditDelta{}}}

      # Break coalescing so undo has something to pop
      BufferProcess.break_undo_coalescing(buf)

      BufferProcess.undo(buf)

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{buffer: ^buf, delta: nil}}
    end
  end

  describe "replace_content broadcasts nil delta with source" do
    test "replace_content sends nil delta" do
      buf = start_supervised!({BufferProcess, content: "old"})
      BufferProcess.replace_content(buf, "new", :lsp)

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: {:lsp, :unknown},
                        delta: nil,
                        sequence: 1
                      }}
    end
  end

  describe "find_and_replace broadcasts with agent source" do
    test "sends nil delta (bulk op)" do
      buf = start_supervised!({BufferProcess, content: "hello world"})
      {:ok, _msg} = BufferProcess.find_and_replace(buf, "hello", "goodbye")

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: {:agent, _, _},
                        delta: nil
                      }}

      assert BufferProcess.content(buf) == "goodbye world"
    end
  end

  describe "event includes version" do
    test "version is set on the event" do
      buf = start_supervised!({BufferProcess, content: ""})
      BufferProcess.insert_char(buf, "a")

      assert_receive {:minga_event, :buffer_changed, %BufferChangedEvent{version: version}}

      assert is_integer(version)
    end
  end
end
