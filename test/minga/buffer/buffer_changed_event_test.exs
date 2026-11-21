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

  describe "ordinary operation receipts" do
    test "BOF backspace and EOF forward delete leave no edit receipt" do
      buf = start_supervised!({BufferProcess, content: "hello"})
      version = BufferProcess.version(buf)

      boundaries = [
        {{0, 0}, &BufferProcess.delete_before/1},
        {{0, 5}, &BufferProcess.delete_at/1}
      ]

      for {cursor, delete} <- boundaries do
        assert :ok = BufferProcess.move_to(buf, cursor)
        assert :ok = delete.(buf)
        assert BufferProcess.content_and_cursor(buf) == {"hello", cursor}
        refute BufferProcess.dirty?(buf)
        assert BufferProcess.version(buf) == version
        assert BufferProcess.last_undo_source(buf) == nil
        assert {:ok, []} = BufferProcess.consume_edit_deltas(buf, :lsp)
        refute_received {:minga_event, :buffer_changed, %BufferChangedEvent{buffer: ^buf}}
      end
    end

    test "an empty insert records a zero-width edit without moving the cursor" do
      buf = start_supervised!({BufferProcess, content: "hello"})
      assert :ok = BufferProcess.move_to(buf, {0, 2})
      version = BufferProcess.version(buf) + 1
      delta = EditDelta.insertion(2, {0, 2}, "", {0, 2})

      assert :ok = BufferProcess.insert_text(buf, "")
      assert BufferProcess.content_and_cursor(buf) == {"hello", {0, 2}}
      assert BufferProcess.dirty?(buf)
      assert BufferProcess.version(buf) == version
      assert BufferProcess.last_undo_source(buf) == :user

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        version: ^version,
                        delta: ^delta
                      }}

      assert {:ok, [^delta]} = BufferProcess.consume_edit_deltas(buf, :lsp)
    end

    test "clearing an empty line records the cursor move but not another clear in place" do
      buf = start_supervised!({BufferProcess, content: "a\n\nb"})
      assert BufferProcess.cursor(buf) == {0, 0}
      version = BufferProcess.version(buf) + 1
      delta = EditDelta.deletion(2, 2, {1, 0}, {1, 0})

      assert {:ok, ""} = BufferProcess.clear_line(buf, 1)
      assert BufferProcess.content_and_cursor(buf) == {"a\n\nb", {1, 0}}
      assert BufferProcess.dirty?(buf)
      assert BufferProcess.version(buf) == version
      assert BufferProcess.last_undo_source(buf) == :user

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :user,
                        version: ^version,
                        delta: ^delta
                      }}

      assert {:ok, [^delta]} = BufferProcess.consume_edit_deltas(buf, :lsp)

      assert {:ok, ""} = BufferProcess.clear_line(buf, 1)
      assert BufferProcess.content_and_cursor(buf) == {"a\n\nb", {1, 0}}
      assert BufferProcess.dirty?(buf)
      assert BufferProcess.version(buf) == version
      assert BufferProcess.last_undo_source(buf) == :user
      assert {:ok, []} = BufferProcess.consume_edit_deltas(buf, :lsp)
      refute_received {:minga_event, :buffer_changed, %BufferChangedEvent{buffer: ^buf}}
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

    test "events preserve the caller's source while undo records its attribution" do
      sources = [
        {EditSource.user(), :user},
        {EditSource.agent(self(), "edit-1"), :agent},
        {EditSource.lsp(:elixir_ls), :lsp},
        {EditSource.formatter(), :lsp},
        {EditSource.unknown(), :user}
      ]

      for {source, undo_source} <- sources do
        buf = start_supervised!({BufferProcess, content: "hello world"}, id: source)
        assert :ok = BufferProcess.apply_edit(buf, 0, 0, 0, 4, "goodbye", source)
        assert BufferProcess.content(buf) == "goodbye world"
        assert BufferProcess.last_undo_source(buf) == undo_source

        assert_receive {:minga_event, :buffer_changed,
                        %BufferChangedEvent{
                          buffer: ^buf,
                          source: ^source,
                          delta: %EditDelta{inserted_text: "goodbye"} = delta
                        }}

        assert {:ok, [^delta]} = BufferProcess.consume_edit_deltas(buf, :lsp)
      end
    end

    test "replacing text with the same bytes still records an edit" do
      buf = start_supervised!({BufferProcess, content: "abc"})
      version = BufferProcess.version(buf) + 1

      assert :ok = BufferProcess.apply_edit(buf, 0, 0, 0, 0, "a")
      assert BufferProcess.content_and_cursor(buf) == {"abc", {0, 1}}
      assert BufferProcess.dirty?(buf)
      assert BufferProcess.version(buf) == version
      assert BufferProcess.last_undo_source(buf) == :user

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        version: ^version,
                        delta:
                          %EditDelta{start_byte: 0, old_end_byte: 1, inserted_text: "a"} = delta
                      }}

      assert {:ok, [^delta]} = BufferProcess.consume_edit_deltas(buf, :lsp)
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

    test "version-checked recovery retains its distinct undo source and resets sync" do
      buf = start_supervised!({BufferProcess, content: "old"})
      version = BufferProcess.version(buf)
      recovered_version = version + 1

      assert {:ok, ^recovered_version} =
               BufferProcess.replace_content_if_version(buf, version, "recovered", :recovery)

      assert BufferProcess.last_undo_source(buf) == :recovery

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{
                        buffer: ^buf,
                        source: :unknown,
                        delta: nil,
                        version: ^recovered_version
                      }}

      assert :reset_required = BufferProcess.consume_edit_deltas(buf, :lsp)
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
