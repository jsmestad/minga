defmodule MingaEditor.Commands.HelpersRegisterTest do
  @moduledoc """
  Tests for register routing logic in `Helpers.put_register`.

  Verifies which registers get written based on the active register,
  operation kind (:yank vs :delete), and uppercase/lowercase semantics.

  Uses constructed EditorState structs with no GenServer. Clipboard sync
  is bypassed via `put_register_with_clipboard_override/5` with `:none`.
  Clipboard sync itself is tested in `clipboard_sync_test.exs`.
  """
  use ExUnit.Case, async: true

  alias MingaEditor.Commands.Helpers
  alias MingaEditor.Editing
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Registers
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp make_state(active_register) do
    %EditorState{
      port_manager: nil,
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        editing: %MingaEditor.VimState{
          mode: :normal,
          mode_state: Minga.Mode.initial_state(),
          reg: %Registers{active: active_register}
        }
      }
    }
  end

  defp put_reg(state, text, kind, type \\ :charwise) do
    Helpers.put_register_with_clipboard_override(state, text, kind, type, :none)
  end

  defp get_reg(state, name), do: Registers.get(Editing.registers(state), name)

  defp seed_register(state, name, text, type) do
    Editing.put_register(state, name, text, type)
  end

  # ── Unnamed register (default, no prefix) ──────────────────────────────

  describe "unnamed register (no prefix)" do
    test "yank writes to unnamed and yank register 0" do
      state = make_state("") |> put_reg("hello\n", :yank, :linewise)

      assert get_reg(state, "") == {"hello\n", :linewise}
      assert get_reg(state, "0") == {"hello\n", :linewise}
    end

    test "delete writes to unnamed but not yank register 0" do
      state = make_state("") |> put_reg("gone\n", :delete, :linewise)

      assert get_reg(state, "") == {"gone\n", :linewise}
      assert get_reg(state, "0") == nil
    end

    test "active register resets to empty after write" do
      state = make_state("") |> put_reg("text", :yank)

      assert Editing.active_register(state) == ""
    end
  end

  # ── Lowercase named register (a-z) ────────────────────────────────────

  describe "lowercase named register" do
    test "yank into named register writes named + unnamed + yank" do
      state = make_state("a") |> put_reg("hello\n", :yank, :linewise)

      assert get_reg(state, "a") == {"hello\n", :linewise}
      assert get_reg(state, "") == {"hello\n", :linewise}
      assert get_reg(state, "0") == {"hello\n", :linewise}
    end

    test "delete into named register writes named + unnamed, skips yank" do
      state = make_state("a") |> put_reg("hello\n", :delete, :linewise)

      assert get_reg(state, "a") == {"hello\n", :linewise}
      assert get_reg(state, "") == {"hello\n", :linewise}
      assert get_reg(state, "0") == nil
    end

    test "two different named registers hold independent values" do
      state =
        make_state("a")
        |> put_reg("alpha\n", :yank, :linewise)

      state = put_in(state.workspace.editing.reg.active, "b")

      state = put_reg(state, "beta\n", :yank, :linewise)

      assert get_reg(state, "a") == {"alpha\n", :linewise}
      assert get_reg(state, "b") == {"beta\n", :linewise}
    end

    test "active register resets to empty after named write" do
      state = make_state("z") |> put_reg("text", :yank)

      assert Editing.active_register(state) == ""
    end
  end

  # ── Uppercase register (append) ───────────────────────────────────────

  describe "uppercase register (append)" do
    test "appends to existing lowercase content" do
      state =
        make_state("")
        |> seed_register("a", "hello\n", :linewise)

      state = put_in(state.workspace.editing.reg.active, "A")
      state = put_reg(state, "world\n", :yank, :linewise)

      assert get_reg(state, "a") == {"hello\nworld\n", :linewise}
    end

    test "appending to an empty register is the same as writing" do
      state = make_state("A") |> put_reg("hello\n", :yank, :linewise)

      assert get_reg(state, "a") == {"hello\n", :linewise}
    end

    test "also writes unnamed and yank register" do
      state = make_state("A") |> put_reg("text\n", :yank, :linewise)

      assert get_reg(state, "") == {"text\n", :linewise}
      assert get_reg(state, "0") == {"text\n", :linewise}
    end

    test "active register resets after append" do
      state = make_state("A") |> put_reg("text", :yank)

      assert Editing.active_register(state) == ""
    end
  end

  # ── Black-hole register (_) ───────────────────────────────────────────

  describe "black-hole register (_)" do
    test "discards text, no registers touched" do
      state =
        make_state("")
        |> seed_register("", "original", :charwise)
        |> seed_register("0", "yanked", :charwise)

      state = put_in(state.workspace.editing.reg.active, "_")
      state = put_reg(state, "should vanish", :delete)

      assert get_reg(state, "") == {"original", :charwise}
      assert get_reg(state, "0") == {"yanked", :charwise}
      assert get_reg(state, "_") == nil
    end

    test "yank into black hole also discards" do
      state = make_state("_") |> put_reg("nope", :yank)

      assert get_reg(state, "") == nil
      assert get_reg(state, "0") == nil
      assert get_reg(state, "_") == nil
    end

    test "active register resets after black-hole write" do
      state = make_state("_") |> put_reg("text", :delete)

      assert Editing.active_register(state) == ""
    end
  end

  # ── Yank register (0) ─────────────────────────────────────────────────

  describe "yank register 0" do
    test "yank stores in 0, delete does not overwrite 0" do
      state =
        make_state("")
        |> put_reg("first\n", :yank, :linewise)

      assert get_reg(state, "0") == {"first\n", :linewise}

      # Now delete something; 0 should be untouched
      state = put_reg(state, "deleted\n", :delete, :linewise)

      assert get_reg(state, "0") == {"first\n", :linewise}
      assert get_reg(state, "") == {"deleted\n", :linewise}
    end

    test "consecutive deletes never update 0" do
      state = make_state("") |> put_reg("yanked\n", :yank, :linewise)

      state = put_reg(state, "del1\n", :delete, :linewise)
      state = put_reg(state, "del2\n", :delete, :linewise)

      assert get_reg(state, "0") == {"yanked\n", :linewise}
    end
  end

  # ── Explicit + register ───────────────────────────────────────────────

  describe "explicit + register" do
    test "writes to unnamed and yank, resets active" do
      # Clipboard write is async and mocked elsewhere; we just verify
      # the register routing (unnamed + yank + reset).
      state = make_state("+") |> put_reg("clip\n", :yank, :linewise)

      assert get_reg(state, "") == {"clip\n", :linewise}
      assert get_reg(state, "0") == {"clip\n", :linewise}
      assert Editing.active_register(state) == ""
    end
  end
end
