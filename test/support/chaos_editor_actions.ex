defmodule Minga.Chaos.EditorActions do
  @moduledoc """
  Functions that execute editor actions against the real headless editor.

  Each function sends input to the editor, waits for the GenServer to
  process it via `:sys.get_state` barrier, and returns a result map
  for postcondition checking.

  These are the "real system" calls that `proper_statem` invokes during
  property evaluation.
  """

  alias Minga.Test.HeadlessPort
  alias Minga.Test.Invariants

  @ctrl 0x02

  # ── Normal mode actions ────────────────────────────────────────────────────

  @doc "Sends a normal-mode motion key."
  @spec normal_motion(map(), atom()) :: map()
  def normal_motion(ctx, motion) do
    cp = motion_codepoint(motion)
    send_key_and_collect(ctx, cp, 0)
  end

  @doc "Enters insert mode via i/a/o/O."
  @spec enter_insert(map(), atom()) :: map()
  def enter_insert(ctx, variant) do
    cp =
      case variant do
        :i -> ?i
        :a -> ?a
        :o -> ?o
        :O -> ?O
      end

    send_key_and_collect(ctx, cp, 0)
  end

  @doc "Enters visual (character) mode."
  @spec enter_visual(map()) :: map()
  def enter_visual(ctx), do: send_key_and_collect(ctx, ?v, 0)

  @doc "Enters visual line mode."
  @spec enter_visual_line(map()) :: map()
  def enter_visual_line(ctx), do: send_key_and_collect(ctx, ?V, 0)

  @doc "Enters command mode."
  @spec enter_command(map()) :: map()
  def enter_command(ctx), do: send_key_and_collect(ctx, ?:, 0)

  @doc "Enters replace mode."
  @spec enter_replace(map()) :: map()
  def enter_replace(ctx), do: send_key_and_collect(ctx, ?R, 0)

  @doc "Sends dd (delete line)."
  @spec delete_line(map()) :: map()
  def delete_line(ctx) do
    send_key_sync(ctx, ?d, 0)
    send_key_and_collect(ctx, ?d, 0)
  end

  @doc "Sends yy (yank line)."
  @spec yank_line(map()) :: map()
  def yank_line(ctx) do
    send_key_sync(ctx, ?y, 0)
    send_key_and_collect(ctx, ?y, 0)
  end

  @doc "Sends x (delete char at cursor)."
  @spec delete_char(map()) :: map()
  def delete_char(ctx), do: send_key_and_collect(ctx, ?x, 0)

  @doc "Sends p (paste after)."
  @spec paste(map()) :: map()
  def paste(ctx), do: send_key_and_collect(ctx, ?p, 0)

  @doc "Sends P (paste before)."
  @spec paste_before(map()) :: map()
  def paste_before(ctx), do: send_key_and_collect(ctx, ?P, 0)

  @doc "Sends u (undo)."
  @spec undo(map()) :: map()
  def undo(ctx), do: send_key_and_collect(ctx, ?u, 0)

  @doc "Sends Ctrl+r (redo)."
  @spec redo(map()) :: map()
  def redo(ctx), do: send_key_and_collect(ctx, ?r, @ctrl)

  # ── Insert mode actions ────────────────────────────────────────────────────

  @doc "Types a printable character in insert mode."
  @spec insert_type(map(), non_neg_integer()) :: map()
  def insert_type(ctx, char), do: send_key_and_collect(ctx, char, 0)

  @doc "Sends Escape (back to normal)."
  @spec escape(map()) :: map()
  def escape(ctx), do: send_key_and_collect(ctx, 27, 0)

  @doc "Sends Enter in insert mode."
  @spec insert_enter(map()) :: map()
  def insert_enter(ctx), do: send_key_and_collect(ctx, 13, 0)

  @doc "Sends Backspace in insert mode."
  @spec insert_backspace(map()) :: map()
  def insert_backspace(ctx), do: send_key_and_collect(ctx, 127, 0)

  # ── Visual mode actions ────────────────────────────────────────────────────

  @doc "Sends a motion in visual mode."
  @spec visual_motion(map(), atom()) :: map()
  def visual_motion(ctx, motion), do: normal_motion(ctx, motion)

  @doc "Deletes selection in visual mode."
  @spec visual_delete(map()) :: map()
  def visual_delete(ctx), do: send_key_and_collect(ctx, ?d, 0)

  @doc "Yanks selection in visual mode."
  @spec visual_yank(map()) :: map()
  def visual_yank(ctx), do: send_key_and_collect(ctx, ?y, 0)

  # ── Command mode actions ───────────────────────────────────────────────────

  @doc "Types a character in command mode."
  @spec command_type(map(), non_neg_integer()) :: map()
  def command_type(ctx, char), do: send_key_and_collect(ctx, char, 0)

  @doc "Sends Enter in command mode (executes the command)."
  @spec command_enter(map()) :: map()
  def command_enter(ctx), do: send_key_and_collect(ctx, 13, 0)

  # ── Scrolling ───────────────────────────────────────────────────────────────

  @doc "Half page down (Ctrl+D)."
  @spec half_page_down(map()) :: map()
  def half_page_down(ctx), do: send_key_and_collect(ctx, ?d, @ctrl)

  @doc "Half page up (Ctrl+U)."
  @spec half_page_up(map()) :: map()
  def half_page_up(ctx), do: send_key_and_collect(ctx, ?u, @ctrl)

  @doc "Full page down (Ctrl+F)."
  @spec page_down(map()) :: map()
  def page_down(ctx), do: send_key_and_collect(ctx, ?f, @ctrl)

  @doc "Full page up (Ctrl+B)."
  @spec page_up(map()) :: map()
  def page_up(ctx), do: send_key_and_collect(ctx, ?b, @ctrl)

  @doc "Mouse wheel up."
  @spec wheel_up(map()) :: map()
  def wheel_up(%{editor: editor} = ctx) do
    send(editor, {:minga_input, {:mouse_event, 10, 10, :wheel_up, 0, :press, 1}})
    sync_barrier(editor)
    Invariants.collect_result(ctx)
  end

  @doc "Mouse wheel down."
  @spec wheel_down(map()) :: map()
  def wheel_down(%{editor: editor} = ctx) do
    send(editor, {:minga_input, {:mouse_event, 10, 10, :wheel_down, 0, :press, 1}})
    sync_barrier(editor)
    Invariants.collect_result(ctx)
  end

  # ── Window management (SPC w ...) ──────────────────────────────────────────

  @doc "Split vertical (SPC w v)."
  @spec split_vertical(map()) :: map()
  def split_vertical(ctx), do: send_leader_and_collect(ctx, [?w, ?v])

  @doc "Split horizontal (SPC w s)."
  @spec split_horizontal(map()) :: map()
  def split_horizontal(ctx), do: send_leader_and_collect(ctx, [?w, ?s])

  @doc "Window left (SPC w h)."
  @spec window_left(map()) :: map()
  def window_left(ctx), do: send_leader_and_collect(ctx, [?w, ?h])

  @doc "Window right (SPC w l)."
  @spec window_right(map()) :: map()
  def window_right(ctx), do: send_leader_and_collect(ctx, [?w, ?l])

  @doc "Window down (SPC w j)."
  @spec window_down(map()) :: map()
  def window_down(ctx), do: send_leader_and_collect(ctx, [?w, ?j])

  @doc "Window up (SPC w k)."
  @spec window_up(map()) :: map()
  def window_up(ctx), do: send_leader_and_collect(ctx, [?w, ?k])

  # ── Buffer management (SPC b ...) ──────────────────────────────────────────

  @doc "Next buffer (SPC b n)."
  @spec buffer_next(map()) :: map()
  def buffer_next(ctx), do: send_leader_and_collect(ctx, [?b, ?n])

  @doc "Previous buffer (SPC b p)."
  @spec buffer_prev(map()) :: map()
  def buffer_prev(ctx), do: send_leader_and_collect(ctx, [?b, ?p])

  # ── File tree (SPC o p) ────────────────────────────────────────────────────

  @doc "Toggle file tree (SPC o p)."
  @spec toggle_file_tree(map()) :: map()
  def toggle_file_tree(ctx), do: send_leader_and_collect(ctx, [?o, ?p])

  # ── Agent view (SPC a a) ───────────────────────────────────────────────────

  @doc "Toggle agentic view (SPC a a)."
  @spec toggle_agent_view(map()) :: map()
  def toggle_agent_view(ctx), do: send_leader_and_collect(ctx, [?a, ?a])

  # ── Tab management (SPC TAB ...) ───────────────────────────────────────────

  @doc "Next tab (SPC TAB n)."
  @spec tab_next(map()) :: map()
  def tab_next(ctx), do: send_leader_and_collect(ctx, [9, ?n])

  @doc "Previous tab (SPC TAB p)."
  @spec tab_prev(map()) :: map()
  def tab_prev(ctx), do: send_leader_and_collect(ctx, [9, ?p])

  # ── Cross-mode actions ─────────────────────────────────────────────────────

  @doc "Sends a resize event."
  @spec resize(map(), pos_integer(), pos_integer()) :: map()
  def resize(%{editor: editor, port: port} = ctx, width, height) do
    HeadlessPort.resize(port, width, height)
    send(editor, {:minga_input, {:resize, width, height}})
    sync_barrier(editor)
    Invariants.collect_result(ctx)
  end

  @doc "Sends a mouse click."
  @spec mouse_click(map(), non_neg_integer(), non_neg_integer()) :: map()
  def mouse_click(%{editor: editor} = ctx, row, col) do
    send(editor, {:minga_input, {:mouse_event, row, col, :left, 0, :press, 1}})
    sync_barrier(editor)
    Invariants.collect_result(ctx)
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp send_leader_and_collect(%{editor: editor} = ctx, keys) do
    # Send SPC (leader) then each subsequent key, with sync barrier after each.
    send(editor, {:minga_input, {:key_press, 32, 0}})
    sync_barrier(editor)

    Enum.each(keys, fn key ->
      send(editor, {:minga_input, {:key_press, key, 0}})
      sync_barrier(editor)
    end)

    Invariants.collect_result(ctx)
  end

  defp send_key_and_collect(%{editor: editor} = ctx, codepoint, mods) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    sync_barrier(editor)
    Invariants.collect_result(ctx)
  end

  defp send_key_sync(%{editor: editor}, codepoint, mods) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    sync_barrier(editor)
  end

  # Synchronization barrier that returns instantly if the process is dead.
  # :sys.get_state uses gen:call internally, which monitors the target.
  # A dead process triggers the monitor immediately (:noproc), so the
  # catch fires in microseconds instead of blocking until a timeout.
  @spec sync_barrier(pid()) :: :ok | :dead
  defp sync_barrier(pid) do
    :sys.get_state(pid)
    :ok
  catch
    :exit, _ -> :dead
  end

  defp motion_codepoint(:h), do: ?h
  defp motion_codepoint(:j), do: ?j
  defp motion_codepoint(:k), do: ?k
  defp motion_codepoint(:l), do: ?l
  defp motion_codepoint(:w), do: ?w
  defp motion_codepoint(:b), do: ?b
  defp motion_codepoint(:e), do: ?e
  defp motion_codepoint(:zero), do: ?0
  defp motion_codepoint(:dollar), do: ?$
end
