defmodule Minga.UI.Panel.MessageStoreTest do
  use ExUnit.Case, async: true

  alias Minga.UI.Panel.MessageStore

  describe "append/4" do
    test "adds an entry with auto-incrementing id" do
      store =
        %MessageStore{}
        |> MessageStore.append("Hello world")

      assert length(store.entries) == 1
      [entry] = store.entries
      assert entry.id == 1
      assert entry.level == :info
      assert entry.subsystem == :editor
      assert entry.text == "Hello world"
      assert store.next_id == 2
    end

    test "appends multiple entries in order" do
      store =
        %MessageStore{}
        |> MessageStore.append("First")
        |> MessageStore.append("Second")
        |> MessageStore.append("Third")

      assert length(store.entries) == 3
      assert Enum.map(store.entries, & &1.id) == [1, 2, 3]
      assert Enum.map(store.entries, & &1.text) == ["First", "Second", "Third"]
    end

    test "trims to 1000 entries" do
      store =
        Enum.reduce(1..1005, %MessageStore{}, fn i, acc ->
          MessageStore.append(acc, "Entry #{i}")
        end)

      assert length(store.entries) == 1000
      # Oldest entries trimmed
      assert hd(store.entries).id == 6
      assert List.last(store.entries).id == 1005
    end

    test "preserves level and subsystem" do
      store = MessageStore.append(%MessageStore{}, "Warning!", :warning, :lsp)
      [entry] = store.entries
      assert entry.level == :warning
      assert entry.subsystem == :lsp
    end

    test "sets timestamp" do
      store = MessageStore.append(%MessageStore{}, "timestamped")
      [entry] = store.entries
      assert %NaiveDateTime{} = entry.timestamp
    end
  end

  describe "entries_since/2" do
    test "returns entries after given id" do
      store =
        %MessageStore{}
        |> MessageStore.append("A")
        |> MessageStore.append("B")
        |> MessageStore.append("C")

      result = MessageStore.entries_since(store, 1)
      assert length(result) == 2
      assert Enum.map(result, & &1.text) == ["B", "C"]
    end

    test "returns all entries when since_id is 0" do
      store =
        %MessageStore{}
        |> MessageStore.append("A")
        |> MessageStore.append("B")

      result = MessageStore.entries_since(store, 0)
      assert length(result) == 2
    end

    test "returns empty list when since_id is current" do
      store = MessageStore.append(%MessageStore{}, "A")
      result = MessageStore.entries_since(store, 1)
      assert result == []
    end
  end

  describe "mark_sent/2" do
    test "updates last_sent_id" do
      store = MessageStore.mark_sent(%MessageStore{}, 42)
      assert store.last_sent_id == 42
    end
  end

  describe "file path extraction" do
    test "extracts path from Opened: messages" do
      store = MessageStore.append(%MessageStore{}, "Opened: lib/minga/editor.ex")
      [entry] = store.entries
      assert entry.file_path == "lib/minga/editor.ex"
    end

    test "extracts path from Saved: messages" do
      store = MessageStore.append(%MessageStore{}, "Saved: lib/minga/buffer.ex")
      [entry] = store.entries
      assert entry.file_path == "lib/minga/buffer.ex"
    end

    test "extracts path from External change detected: messages" do
      store = MessageStore.append(%MessageStore{}, "External change detected: lib/foo.ex")
      [entry] = store.entries
      assert entry.file_path == "lib/foo.ex"
    end

    test "returns nil for messages without file paths" do
      store = MessageStore.append(%MessageStore{}, "Editor started")
      [entry] = store.entries
      assert entry.file_path == nil
    end
  end

  describe "parse_prefix/1" do
    test "parses ZIG prefixes" do
      assert {:error, :zig, "crash"} = MessageStore.parse_prefix("[ZIG/err] crash")
      assert {:warning, :zig, "slow"} = MessageStore.parse_prefix("[ZIG/warn] slow")
      assert {:info, :zig, "ok"} = MessageStore.parse_prefix("[ZIG/info] ok")
      assert {:debug, :zig, "trace"} = MessageStore.parse_prefix("[ZIG/debug] trace")
    end

    test "parses GUI prefixes" do
      assert {:error, :gui, "fail"} = MessageStore.parse_prefix("[GUI/err] fail")
      assert {:info, :gui, "ready"} = MessageStore.parse_prefix("[GUI/info] ready")
    end

    test "parses PARSER prefixes" do
      assert {:error, :parser, "bad"} = MessageStore.parse_prefix("[PARSER/err] bad")
      assert {:warning, :parser, "hmm"} = MessageStore.parse_prefix("[PARSER/warn] hmm")
    end

    test "parses LSP prefix" do
      assert {:info, :lsp, "connected"} = MessageStore.parse_prefix("[LSP] connected")
    end

    test "parses render prefix" do
      assert {:debug, :render, "[render:content] 24µs"} =
               MessageStore.parse_prefix("[render:content] 24µs")
    end

    test "defaults to info/editor" do
      assert {:info, :editor, "Editor started"} = MessageStore.parse_prefix("Editor started")
    end
  end

  describe "encoding helpers" do
    test "level_byte/1" do
      assert MessageStore.level_byte(:debug) == 0
      assert MessageStore.level_byte(:info) == 1
      assert MessageStore.level_byte(:warning) == 2
      assert MessageStore.level_byte(:error) == 3
    end

    test "subsystem_byte/1" do
      assert MessageStore.subsystem_byte(:editor) == 0
      assert MessageStore.subsystem_byte(:lsp) == 1
      assert MessageStore.subsystem_byte(:parser) == 2
      assert MessageStore.subsystem_byte(:git) == 3
      assert MessageStore.subsystem_byte(:render) == 4
      assert MessageStore.subsystem_byte(:agent) == 5
      assert MessageStore.subsystem_byte(:zig) == 6
      assert MessageStore.subsystem_byte(:gui) == 7
    end
  end
end
