defmodule Minga.Editor.RegistersTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  @content "hello\nworld\nfoo"

  defp start_editor(content \\ @content) do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_reg_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  defp state(editor), do: :sys.get_state(editor)

  # ── Register selection via " prefix ───────────────────────────────────────

  describe "register selection" do
    test ~S["a selects register a] do
      {editor, _buffer} = start_editor()
      send_key(editor, ?")
      send_key(editor, ?a)
      assert state(editor).workspace.vim.reg.active == "a"
    end

    test ~S["A selects register A for appending] do
      {editor, _buffer} = start_editor()
      send_key(editor, ?")
      send_key(editor, ?A)
      assert state(editor).workspace.vim.reg.active == "A"
    end

    test ~S["0 selects the yank register] do
      {editor, _buffer} = start_editor()
      send_key(editor, ?")
      send_key(editor, ?0)
      assert state(editor).workspace.vim.reg.active == "0"
    end

    test ~S["_ selects the black-hole register] do
      {editor, _buffer} = start_editor()
      send_key(editor, ?")
      send_key(editor, ?_)
      assert state(editor).workspace.vim.reg.active == "_"
    end

    test ~S["" selects the unnamed register] do
      {editor, _buffer} = start_editor()
      send_key(editor, ?")
      send_key(editor, ?")
      assert state(editor).workspace.vim.reg.active == ""
    end

    test "invalid register char cancels selection" do
      {editor, _buffer} = start_editor()
      send_key(editor, ?")
      send_key(editor, ?!)
      assert state(editor).workspace.vim.reg.active == ""
    end

    test "active_register resets to empty after an operation" do
      {editor, buffer} = start_editor()
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?y)
      send_key(editor, ?y)
      assert state(editor).workspace.vim.reg.active == ""
    end
  end

  # ── Named register yank and paste ─────────────────────────────────────────

  describe "named register yank and paste" do
    test ~S["ayy stores in register a, also in 0 and unnamed] do
      {editor, buffer} = start_editor("hello\nworld")
      BufferServer.move_to(buffer, {0, 0})

      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?y)
      send_key(editor, ?y)

      s = state(editor)
      assert Map.get(s.workspace.vim.reg.registers, "a") == {"hello\n", :linewise}
      assert Map.get(s.workspace.vim.reg.registers, "0") == {"hello\n", :linewise}
      assert Map.get(s.workspace.vim.reg.registers, "") == {"hello\n", :linewise}
    end

    test ~S["ayy / "ap round-trip pastes from register a] do
      {editor, buffer} = start_editor("hello\nworld")
      BufferServer.move_to(buffer, {0, 0})

      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?y)
      send_key(editor, ?y)

      BufferServer.move_to(buffer, {1, 4})
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?p)

      assert String.contains?(BufferServer.content(buffer), "hello")
    end

    test "two different named registers hold independent values" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?y)
      send_key(editor, ?y)

      BufferServer.move_to(buffer, {1, 0})
      send_key(editor, ?")
      send_key(editor, ?b)
      send_key(editor, ?y)
      send_key(editor, ?y)

      s = state(editor)
      assert Map.get(s.workspace.vim.reg.registers, "a") == {"hello\n", :linewise}
      assert Map.get(s.workspace.vim.reg.registers, "b") == {"world\n", :linewise}
    end
  end

  # ── Uppercase registers (append) ──────────────────────────────────────────

  describe "uppercase register appends" do
    test ~S["Ayy appends to register a] do
      {editor, buffer} = start_editor("hello\nworld")
      BufferServer.move_to(buffer, {0, 0})

      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?y)
      send_key(editor, ?y)

      BufferServer.move_to(buffer, {1, 0})
      send_key(editor, ?")
      send_key(editor, ?A)
      send_key(editor, ?y)
      send_key(editor, ?y)

      s = state(editor)
      assert Map.get(s.workspace.vim.reg.registers, "a") == {"hello\nworld\n", :linewise}
    end

    test "appending to an empty register is the same as writing" do
      {editor, buffer} = start_editor("hello")
      BufferServer.move_to(buffer, {0, 0})

      send_key(editor, ?")
      send_key(editor, ?A)
      send_key(editor, ?y)
      send_key(editor, ?y)

      assert Map.get(state(editor).workspace.vim.reg.registers, "a") == {"hello\n", :linewise}
    end
  end

  # ── Yank register "0 ──────────────────────────────────────────────────────

  describe ~S["0 yank register] do
    test "yank stores in 0, delete does not overwrite 0" do
      {editor, buffer} = start_editor("hello\nworld")
      BufferServer.move_to(buffer, {0, 0})

      send_key(editor, ?y)
      send_key(editor, ?y)
      assert Map.get(state(editor).workspace.vim.reg.registers, "0") == {"hello\n", :linewise}

      BufferServer.move_to(buffer, {1, 0})
      send_key(editor, ?d)
      send_key(editor, ?d)

      s = state(editor)
      assert Map.get(s.workspace.vim.reg.registers, "0") == {"hello\n", :linewise}
      assert Map.get(s.workspace.vim.reg.registers, "") == {"world\n", :linewise}
    end

    test "consecutive deletes do not update 0" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")

      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)

      BufferServer.move_to(buffer, {1, 0})
      send_key(editor, ?d)
      send_key(editor, ?d)
      send_key(editor, ?d)
      send_key(editor, ?d)

      assert Map.get(state(editor).workspace.vim.reg.registers, "0") == {"hello\n", :linewise}
    end
  end

  # ── Black-hole register "_ ────────────────────────────────────────────────

  describe ~S["_ black-hole register] do
    test ~S["_dd deletes without touching any register] do
      {editor, buffer} = start_editor("hello\nworld")
      BufferServer.move_to(buffer, {0, 0})

      send_key(editor, ?y)
      send_key(editor, ?y)
      assert Map.get(state(editor).workspace.vim.reg.registers, "") == {"hello\n", :linewise}

      BufferServer.move_to(buffer, {1, 0})
      send_key(editor, ?")
      send_key(editor, ?_)
      send_key(editor, ?d)
      send_key(editor, ?d)

      s = state(editor)
      assert Map.get(s.workspace.vim.reg.registers, "") == {"hello\n", :linewise}
      assert Map.get(s.workspace.vim.reg.registers, "0") == {"hello\n", :linewise}
      refute Map.has_key?(s.workspace.vim.reg.registers, "_")
    end

    test ~S["_yy yanks into black hole — registers unchanged] do
      {editor, buffer} = start_editor("hello\nworld")
      BufferServer.move_to(buffer, {0, 0})

      send_key(editor, ?y)
      send_key(editor, ?y)
      previous_unnamed = Map.get(state(editor).workspace.vim.reg.registers, "")

      send_key(editor, ?")
      send_key(editor, ?_)
      send_key(editor, ?y)
      send_key(editor, ?y)

      assert Map.get(state(editor).workspace.vim.reg.registers, "") == previous_unnamed
    end
  end

  # ── Unnamed register default behaviour ────────────────────────────────────

  describe "unnamed register default behaviour" do
    test "yy without prefix writes to unnamed" do
      {editor, buffer} = start_editor("hello")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      assert Map.get(state(editor).workspace.vim.reg.registers, "") == {"hello\n", :linewise}
    end

    test "dd without prefix writes to unnamed" do
      {editor, buffer} = start_editor("hello\nworld")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?d)
      send_key(editor, ?d)
      assert Map.get(state(editor).workspace.vim.reg.registers, "") == {"hello\n", :linewise}
    end

    test "p pastes from unnamed when no register selected" do
      {editor, buffer} = start_editor("hello\nworld")
      BufferServer.move_to(buffer, {0, 0})
      send_key(editor, ?y)
      send_key(editor, ?y)
      BufferServer.move_to(buffer, {1, 4})
      send_key(editor, ?p)
      assert String.contains?(BufferServer.content(buffer), "hello")
    end

    test "p is no-op when unnamed register is empty" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)
      send_key(editor, ?p)
      assert BufferServer.content(buffer) == original
    end

    test "P is no-op when unnamed register is empty" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)
      send_key(editor, ?P)
      assert BufferServer.content(buffer) == original
    end
  end

  # ── Named register paste is independent of unnamed ────────────────────────

  describe "named register paste independence" do
    test ~S["ap pastes from a even after unnamed is overwritten by a delete] do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      BufferServer.move_to(buffer, {0, 0})

      # Yank line 0 into register a
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?y)
      send_key(editor, ?y)

      # Delete line 1, overwriting unnamed
      BufferServer.move_to(buffer, {1, 0})
      send_key(editor, ?d)
      send_key(editor, ?d)

      s = state(editor)
      assert Map.get(s.workspace.vim.reg.registers, "") == {"world\n", :linewise}
      assert Map.get(s.workspace.vim.reg.registers, "a") == {"hello\n", :linewise}

      # "ap should paste "hello" from register a
      send_key(editor, ?")
      send_key(editor, ?a)
      send_key(editor, ?p)

      assert String.contains?(BufferServer.content(buffer), "hello")
    end
  end
end
