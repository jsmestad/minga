defmodule Minga.IntegrationTest do
  @moduledoc """
  End-to-end integration tests that exercise the full editor pipeline:
  buffer → editor FSM → command execution → buffer state verification.

  Uses `port_manager: nil` so no Zig renderer is needed — the editor simply
  logs a warning when it tries to send render commands.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  @moduletag :tmp_dir

  # ── Test helpers ─────────────────────────────────────────────────────────────

  # Starts a fresh editor + buffer pair. `content` is the initial buffer text.
  @spec start_editor(String.t()) :: {pid(), pid()}
  defp start_editor(content) do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"integration_editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 80,
        height: 24
      )

    {editor, buffer}
  end

  # Sends a key event (codepoint + optional modifiers) and waits for the
  # GenServer to finish processing.
  @spec send_key(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    Process.sleep(30)
    :ok
  end

  # Sends a sequence of printable ASCII key events.
  @spec type_string(pid(), String.t()) :: :ok
  defp type_string(editor, text) do
    text
    |> String.to_charlist()
    |> Enum.each(fn char -> send_key(editor, char) end)

    :ok
  end

  # ── Normal mode navigation ────────────────────────────────────────────────────

  describe "Normal mode — hjkl navigation" do
    test "l moves cursor right, content unchanged" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      original = BufferServer.content(buffer)

      send_key(editor, ?l)
      send_key(editor, ?l)

      assert BufferServer.content(buffer) == original
      assert BufferServer.cursor(buffer) == {0, 2}
    end

    test "h moves cursor left" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")

      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?h)

      assert BufferServer.cursor(buffer) == {0, 1}
    end

    test "j moves cursor down, k moves cursor up" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")

      send_key(editor, ?j)
      assert elem(BufferServer.cursor(buffer), 0) == 1

      send_key(editor, ?k)
      assert elem(BufferServer.cursor(buffer), 0) == 0
    end

    test "multiple l moves advance the column" do
      {editor, buffer} = start_editor("hello world")

      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?l)

      {_line, col} = BufferServer.cursor(buffer)
      assert col == 3
    end

    test "0 moves to beginning of line" do
      {editor, buffer} = start_editor("hello\nworld")

      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?0)

      assert BufferServer.cursor(buffer) == {0, 0}
    end
  end

  # ── Insert mode ───────────────────────────────────────────────────────────────

  describe "Insert mode — typing and escaping" do
    test "i enters insert mode and characters are inserted" do
      {editor, buffer} = start_editor("hello")

      send_key(editor, ?i)
      type_string(editor, "abc")

      assert BufferServer.content(buffer) == "abchello"
    end

    test "Escape returns to normal mode — subsequent keys move, not insert" do
      {editor, buffer} = start_editor("hello")

      send_key(editor, ?i)
      type_string(editor, "x")
      send_key(editor, 27)

      # In normal mode now — 'l' should move, not insert
      content_after_insert = BufferServer.content(buffer)
      send_key(editor, ?l)

      assert BufferServer.content(buffer) == content_after_insert
    end

    test "backspace (127) deletes the previous character in insert mode" do
      {editor, buffer} = start_editor("hello")

      send_key(editor, ?i)
      send_key(editor, ?a)
      send_key(editor, 127)

      assert BufferServer.content(buffer) == "hello"
    end

    test "Enter (13) inserts a newline in insert mode" do
      {editor, buffer} = start_editor("hello")

      send_key(editor, ?i)
      send_key(editor, 13)

      content = BufferServer.content(buffer)
      assert String.contains?(content, "\n")
    end

    test "a moves right before entering insert mode" do
      {editor, buffer} = start_editor("hi")

      send_key(editor, ?a)
      type_string(editor, "!")

      content = BufferServer.content(buffer)
      assert String.contains?(content, "!")
    end
  end

  # ── Delete operations ─────────────────────────────────────────────────────────

  describe "dd — delete current line" do
    test "dd deletes the current line and moves cursor" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")

      # Press d twice in normal mode (operator_pending)
      send_key(editor, ?d)
      send_key(editor, ?d)

      content = BufferServer.content(buffer)
      refute String.contains?(content, "hello")
      assert String.contains?(content, "world")
    end

    test "dd on a single-line buffer leaves it empty or minimal" do
      {editor, buffer} = start_editor("only line")

      send_key(editor, ?d)
      send_key(editor, ?d)

      content = BufferServer.content(buffer)
      refute String.contains?(content, "only")
    end
  end

  # ── Undo ──────────────────────────────────────────────────────────────────────

  describe "u — undo" do
    test "u after inserting reverts the buffer" do
      {editor, buffer} = start_editor("hello")

      send_key(editor, ?i)
      type_string(editor, "x")
      send_key(editor, 27)

      assert BufferServer.content(buffer) == "xhello"

      send_key(editor, ?u)

      assert BufferServer.content(buffer) == "hello"
    end

    test "u after dd reverts the deletion" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")

      send_key(editor, ?d)
      send_key(editor, ?d)

      refute String.contains?(BufferServer.content(buffer), "hello")

      send_key(editor, ?u)

      assert String.contains?(BufferServer.content(buffer), "hello")
    end

    test "u on unchanged buffer is a no-op" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)

      send_key(editor, ?u)

      assert BufferServer.content(buffer) == original
    end

    test "multiple undo steps revert in order" do
      {editor, buffer} = start_editor("hello")

      send_key(editor, ?i)
      send_key(editor, ?a)
      send_key(editor, ?b)
      send_key(editor, 27)

      assert BufferServer.content(buffer) == "abhello"

      send_key(editor, ?u)
      after_one_undo = BufferServer.content(buffer)

      send_key(editor, ?u)
      after_two_undo = BufferServer.content(buffer)

      # Each undo should revert one insertion
      assert String.length(after_one_undo) < String.length("abhello")
      assert String.length(after_two_undo) < String.length(after_one_undo)
    end
  end

  # ── Paste ─────────────────────────────────────────────────────────────────────

  describe "p / P — paste" do
    test "p pastes register text after cursor after yy" do
      {editor, buffer} = start_editor("hello\nworld")

      # Yank current line (yy)
      send_key(editor, ?y)
      send_key(editor, ?y)

      # Move down and paste
      send_key(editor, ?j)
      send_key(editor, ?p)

      content = BufferServer.content(buffer)
      lines = String.split(content, "\n")
      assert length(lines) >= 3
    end

    test "P pastes register text before cursor" do
      {editor, buffer} = start_editor("hello\nworld")

      send_key(editor, ?y)
      send_key(editor, ?y)

      send_key(editor, ?j)
      send_key(editor, ?P)

      content = BufferServer.content(buffer)
      assert String.contains?(content, "hello")
    end

    test "p is a no-op when register is empty" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)

      # No yank — register should be nil
      send_key(editor, ?p)

      assert BufferServer.content(buffer) == original
    end
  end

  # ── Command mode (:w) ─────────────────────────────────────────────────────────

  describe ":w — save via command mode" do
    test "saves buffer to a tmp file via :w command", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "integration_save.txt")
      {:ok, buffer} = BufferServer.start_link(file_path: path, content: "save me")

      {:ok, editor} =
        Editor.start_link(
          name: :"integration_save_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buffer,
          width: 80,
          height: 24
        )

      # Type some content in insert mode, then escape
      send_key(editor, ?i)
      type_string(editor, "extra ")
      send_key(editor, 27)

      # Enter command mode and type :w<Enter>
      send_key(editor, ?:)
      send_key(editor, ?w)
      send_key(editor, 13)

      # Wait for the file system write
      Process.sleep(50)

      assert File.exists?(path)
      assert String.contains?(File.read!(path), "extra")
    end
  end

  # ── Full pipeline smoke test ──────────────────────────────────────────────────

  describe "full pipeline smoke test" do
    test "navigate, insert, delete, undo flow leaves editor alive" do
      {editor, buffer} = start_editor("line one\nline two\nline three")

      # Navigate
      send_key(editor, ?j)
      send_key(editor, ?l)
      send_key(editor, ?l)

      # Enter insert mode and type
      send_key(editor, ?i)
      type_string(editor, "INSERTED")
      send_key(editor, 27)

      content_after_insert = BufferServer.content(buffer)
      assert String.contains?(content_after_insert, "INSERTED")

      # Delete the line
      send_key(editor, ?d)
      send_key(editor, ?d)

      refute String.contains?(BufferServer.content(buffer), "INSERTED")

      # Undo the delete
      send_key(editor, ?u)

      assert String.contains?(BufferServer.content(buffer), "INSERTED")

      # Editor stays alive throughout
      assert Process.alive?(editor)
      assert Process.alive?(buffer)
    end
  end
end
