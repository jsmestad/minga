defmodule MingaEditor.Mouse do
  @moduledoc """
  Mouse event handling for the editor.

  Handles scroll, click, drag, and release events, translating screen
  coordinates to buffer positions. All functions are pure `state -> state`
  transformations; the buffer is mutated via `Buffer` calls, but the
  GenServer state struct is returned unchanged or updated.

  ## Multi-click selection

  * Double-click: select word under cursor, enter Visual mode
  * Triple-click: select entire line, enter Visual Line mode
  * Double-click + drag: extend selection word-by-word
  * Triple-click + drag: extend selection line-by-line

  ## Modifier clicks

  * Shift+click: extend visual selection to click position
  * Cmd/Super+click: go-to-definition (when LSP active)
  * Middle-click: paste at click position

  ## Horizontal scroll

  * Wheel left/right: shift viewport horizontally
  """

  import Bitwise

  alias Minga.Buffer
  alias Minga.Config
  alias Minga.Editing
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias MingaEditor.DisplayMap
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias MingaEditor.Layout.SurfaceRegistry
  alias MingaEditor.Mouse.HitTest
  alias MingaEditor.Mouse.Target.Buffer, as: BufferTarget
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Mouse, as: MouseState
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Highlight
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowFocus
  alias MingaEditor.WindowTree

  alias MingaEditor.Frontend.Capabilities
  alias Minga.Mode.VisualState

  # TUI scrolls 3 lines per wheel tick (standard terminal behavior).
  # GUI scrolls 1 line/col per event because the frontend accumulates pixel
  # deltas and emits one event per cell boundary crossed.
  @gui_scroll_lines 1
  @gui_scroll_cols 1
  @scroll_cols 6

  # Modifier flags
  @mod_shift 0x01
  @mod_ctrl 0x02
  @mod_super 0x08

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typep fold_gutter_target ::
           {:window_fold, Window.id(), non_neg_integer()} | {:decoration_fold, pid(), reference()}

  @typep fold_row_target :: {:window_fold, non_neg_integer()} | {:decoration_fold, reference()}
  @typep drag_window_context ::
           {Window.id(), Window.t(), pid(), integer(), integer(), pos_integer(), pos_integer()}
  @typep tab_command ::
           atom() | {:workspace_goto, non_neg_integer()} | {:tab_goto_id, pos_integer()}
  @typep text_target :: BufferTarget.t() | TextTarget.t()
  @typep text_position :: {non_neg_integer(), non_neg_integer()}
  @typep target_move :: (text_position() -> {:ok, text_position()} | {:error, atom()})

  @doc "Applies a frontend text-pointer event whose source target was resolved by the renderer."
  @spec handle_text_event(state(), TextEvent.t(), TextTarget.t() | nil) :: state()
  def handle_text_event(state, %TextEvent{button: :left, event_type: :release}, _target) do
    handle(state, 0, 0, :left, 0, :release, 1)
  end

  def handle_text_event(state, %TextEvent{}, nil), do: state

  def handle_text_event(state, %TextEvent{event_type: :drag} = event, %TextTarget{} = target),
    do: handle_text_drag(state, event, target)

  def handle_text_event(state, %TextEvent{event_type: :motion} = event, %TextTarget{} = target),
    do: handle_text_motion(state, event, target)

  def handle_text_event(state, %TextEvent{button: :middle, event_type: :press}, target),
    do: apply_middle_press(state, target)

  def handle_text_event(state, %TextEvent{button: :right, event_type: :press}, target),
    do: apply_context_press(state, target)

  def handle_text_event(state, %TextEvent{button: :left, event_type: :press} = event, target),
    do: handle_text_left_press(state, event, target)

  def handle_text_event(state, %TextEvent{}, %TextTarget{}), do: state

  @spec handle_text_left_press(state(), TextEvent.t(), TextTarget.t()) :: state()
  defp handle_text_left_press(original, event, target) do
    case validate_target(target) do
      {:ok, _position} -> record_and_apply_text_press(original, event, target)
      {:error, _reason} -> original
    end
  catch
    :exit, _reason -> original
  end

  @spec record_and_apply_text_press(state(), TextEvent.t(), TextTarget.t()) :: state()
  defp record_and_apply_text_press(original, event, target) do
    mouse =
      MouseState.record_text_press_at(
        original.workspace.mouse,
        event.window_id,
        target.buffer,
        target.source_version,
        event.row_id,
        event.utf16_offset,
        event.click_count,
        System.monotonic_time(:millisecond)
      )

    state = %{
      original
      | workspace: MingaEditor.Session.State.set_mouse(original.workspace, mouse)
    }

    handle_text_left_press_kind(
      original,
      state,
      target,
      event.mods,
      MouseState.click_count(mouse)
    )
  end

  @spec handle_text_left_press_kind(
          state(),
          state(),
          TextTarget.t(),
          non_neg_integer(),
          pos_integer()
        ) :: state()
  defp handle_text_left_press_kind(_original, state, target, mods, _click_count)
       when band(mods, @mod_shift) != 0,
       do: apply_shift_click(state, target)

  defp handle_text_left_press_kind(original, state, target, mods, _click_count)
       when band(mods, @mod_super) != 0,
       do: apply_goto_definition(original, state, target)

  defp handle_text_left_press_kind(
         _original,
         %{frontend: %{capabilities: %Capabilities{frontend_type: :native_gui}}} = state,
         target,
         mods,
         _click_count
       )
       when band(mods, @mod_ctrl) != 0,
       do: apply_context_press(state, target)

  defp handle_text_left_press_kind(original, state, target, mods, _click_count)
       when band(mods, @mod_ctrl) != 0,
       do: apply_goto_definition(original, state, target)

  defp handle_text_left_press_kind(_original, state, target, _mods, 2),
    do: apply_double_click(state, target)

  defp handle_text_left_press_kind(_original, state, target, _mods, 3),
    do: apply_triple_click(state, target)

  defp handle_text_left_press_kind(_original, state, target, _mods, _click_count),
    do: apply_plain_click(state, target)

  @spec apply_plain_click(state(), text_target()) :: state()
  defp apply_plain_click(state, target) do
    case focus_and_move_target(state, target, target_position(target)) do
      {:ok, focused, position} ->
        focused
        |> normalize_mode_for_targeted_gesture()
        |> update_mouse(&start_target_drag(&1, position, target))

      _ ->
        state
    end
  catch
    :exit, _reason -> state
  end

  @spec apply_double_click(state(), text_target()) :: state()
  defp apply_double_click(state, target) do
    {line, byte} = target_position(target)

    with {{start_line, start_byte}, {end_line, end_byte}} <-
           word_boundaries_at(target_buffer(target), line, byte),
         {:ok, focused, _position} <-
           focus_and_move_target(state, target, {end_line, end_byte}) do
      workspace =
        MingaEditor.Session.State.transition_mode(
          focused.workspace,
          :visual,
          %VisualState{visual_anchor: {start_line, start_byte}, visual_type: :char}
        )

      %{focused | workspace: workspace}
      |> update_mouse(&start_target_drag(&1, {start_line, start_byte}, target))
    else
      _ -> state
    end
  catch
    :exit, _reason -> state
  end

  @spec apply_triple_click(state(), text_target()) :: state()
  defp apply_triple_click(state, target) do
    {line, _byte} = target_position(target)
    line_text = cursor_line_text(target_buffer(target), line)
    end_position = {line, max(byte_size(line_text) - 1, 0)}

    case focus_and_move_target(state, target, end_position) do
      {:ok, focused, _position} ->
        workspace =
          MingaEditor.Session.State.transition_mode(
            focused.workspace,
            :visual,
            %VisualState{visual_anchor: {line, 0}, visual_type: :line}
          )

        %{focused | workspace: workspace}
        |> update_mouse(&start_target_drag(&1, {line, 0}, target))

      _ ->
        state
    end
  catch
    :exit, _reason -> state
  end

  @spec apply_shift_click(state(), text_target()) :: state()
  defp apply_shift_click(state, target) do
    buffer = target_buffer(target)

    anchor =
      case {state.workspace.buffers.active, Minga.Editing.mode(state)} do
        {^buffer, :visual} -> MingaEditor.Editing.visual_anchor(state)
        _ -> Buffer.cursor(buffer)
      end

    case focus_and_move_target(state, target, target_position(target)) do
      {:ok, focused, _position} ->
        workspace =
          MingaEditor.Session.State.transition_mode(
            focused.workspace,
            :visual,
            %VisualState{visual_anchor: anchor, visual_type: :char}
          )

        %{focused | workspace: workspace}

      _ ->
        state
    end
  catch
    :exit, _reason -> state
  end

  @spec apply_middle_press(state(), text_target()) :: state()
  defp apply_middle_press(state, target) do
    case focus_and_move_target(state, target, target_position(target)) do
      {:ok, focused, _position} ->
        focused
        |> normalize_mode_for_targeted_gesture()
        |> MingaEditor.dispatch_command(:paste_after)

      _ ->
        state
    end
  catch
    :exit, _reason -> state
  end

  @spec apply_goto_definition(state(), state(), text_target()) :: state()
  defp apply_goto_definition(original, state, target) do
    case focus_and_move_target(state, target, target_position(target)) do
      {:ok, focused, _position} ->
        focused
        |> clear_cmd_hover_link_for_targeted_gesture()
        |> normalize_mode_for_targeted_gesture()
        |> MingaEditor.dispatch_command(:goto_definition)

      _ ->
        original
    end
  catch
    :exit, _reason -> original
  end

  @spec apply_context_press(state(), text_target()) :: state()
  defp apply_context_press(state, target) do
    with {:ok, position} <- validate_target(target),
         {:ok, focused} <- focus_target(state, target) do
      preserve? =
        state.workspace.buffers.active == target_buffer(target) and
          click_inside_visual_selection?(state, elem(position, 0), elem(position, 1))

      apply_context_position(state, focused, target, preserve?)
    else
      _ -> state
    end
  catch
    :exit, _reason -> state
  end

  @spec apply_context_position(state(), state(), text_target(), boolean()) :: state()
  defp apply_context_position(_original, focused, _target, true), do: focused

  defp apply_context_position(original, focused, target, false) do
    case move_target(target, target_position(target)) do
      {:ok, _position} -> normalize_mode_for_targeted_gesture(focused)
      {:error, _reason} -> original
    end
  end

  @spec handle_text_drag(state(), TextEvent.t(), TextTarget.t()) :: state()
  defp handle_text_drag(state, event, %TextTarget{} = target) do
    case MouseState.active_text_drag(state.workspace.mouse) do
      {:active, anchor, origin_window, buffer, source_version, click_count}
      when origin_window == target.window_id and buffer == target.buffer and
             source_version == target.source_version ->
        case validate_target(target) do
          {:ok, position} ->
            state
            |> text_drag_auto_scroll(origin_window, event.scroll_x, event.scroll_y)
            |> update_drag_selection(
              target.buffer,
              anchor,
              click_count,
              position,
              &move_target(target, &1)
            )

          {:error, _reason} ->
            state
        end

      _inactive_or_different_source ->
        state
    end
  catch
    :exit, _reason -> state
  end

  @spec text_drag_auto_scroll(state(), Window.id(), -1 | 0 | 1, -1 | 0 | 1) :: state()
  defp text_drag_auto_scroll(state, window_id, scroll_x, scroll_y) do
    state =
      case scroll_y do
        -1 -> scroll_window_vertical(state, window_id, -1)
        1 -> scroll_window_vertical(state, window_id, 1)
        0 -> state
      end

    case scroll_x do
      -1 -> scroll_window_horizontal(state, window_id, -scroll_cols(state))
      1 -> scroll_window_horizontal(state, window_id, scroll_cols(state))
      0 -> state
    end
  end

  @spec handle_text_motion(state(), TextEvent.t(), TextTarget.t()) :: state()
  defp handle_text_motion(state, event, %TextTarget{} = target) do
    case validate_target(target) do
      {:ok, _position} -> handle_text_motion_modifiers(state, event, target)
      {:error, _reason} -> state
    end
  catch
    :exit, _reason -> state
  end

  @spec handle_text_motion_modifiers(state(), TextEvent.t(), TextTarget.t()) :: state()
  defp handle_text_motion_modifiers(state, %{mods: mods}, target)
       when band(mods, @mod_super) != 0 do
    set_cmd_hover_link_if_changed(state, navigable_link_at_text_target(state, target))
  end

  defp handle_text_motion_modifiers(
         %{frontend: %{capabilities: %Capabilities{frontend_type: :native_gui}}} = state,
         %{mods: mods},
         _target
       )
       when band(mods, @mod_ctrl) != 0,
       do: clear_cmd_hover_link_for_targeted_gesture(state)

  defp handle_text_motion_modifiers(state, %{mods: mods}, target)
       when band(mods, @mod_ctrl) != 0 do
    set_cmd_hover_link_if_changed(state, navigable_link_at_text_target(state, target))
  end

  defp handle_text_motion_modifiers(state, _event, _target),
    do: clear_cmd_hover_link_for_targeted_gesture(state)

  @spec navigable_link_at_text_target(state(), TextTarget.t()) :: EditorState.cmd_hover_link()
  defp navigable_link_at_text_target(
         %{workspace: %{buffers: %{active: buffer}}} = state,
         %TextTarget{buffer: buffer, line: line, byte: byte}
       ),
       do: navigable_link_at_pos(state, line, byte)

  defp navigable_link_at_text_target(_state, _target), do: nil

  @spec start_target_drag(MouseState.t(), text_position(), text_target()) :: MouseState.t()
  defp start_target_drag(mouse, anchor, %BufferTarget{} = target),
    do: MouseState.start_drag(mouse, anchor, target.window_id)

  defp start_target_drag(mouse, anchor, %TextTarget{} = target),
    do:
      MouseState.start_text_drag(
        mouse,
        anchor,
        target.window_id,
        target.buffer,
        target.source_version
      )

  @spec target_position(text_target()) :: text_position()
  defp target_position(%BufferTarget{} = target), do: BufferTarget.position(target)
  defp target_position(%TextTarget{} = target), do: TextTarget.position(target)

  @spec target_buffer(text_target()) :: pid()
  defp target_buffer(%{buffer: buffer}), do: buffer

  @spec target_window_id(text_target()) :: Window.id()
  defp target_window_id(%{window_id: window_id}), do: window_id

  @spec focus_target(state(), text_target()) :: {:ok, state()} | {:error, atom()}
  defp focus_target(state, target),
    do: WindowFocus.focus_buffer_result(state, target_window_id(target), target_buffer(target))

  @spec focus_and_move_target(state(), text_target(), text_position()) ::
          {:ok, state(), text_position()} | {:error, atom()}
  defp focus_and_move_target(state, target, position) do
    with {:ok, _position} <- validate_target(target),
         {:ok, focused} <- focus_target(state, target),
         {:ok, moved_position} <- move_target(target, position) do
      {:ok, focused, moved_position}
    end
  end

  @spec move_target(text_target(), text_position()) ::
          {:ok, text_position()} | {:error, atom()}
  defp move_target(%BufferTarget{buffer: buffer}, position) do
    :ok = Buffer.move_to(buffer, position)
    {:ok, position}
  end

  defp move_target(%TextTarget{} = target, position),
    do: Buffer.move_to_if_version(target.buffer, target.source_version, position)

  @spec validate_target(text_target()) :: {:ok, text_position()} | {:error, atom()}
  defp validate_target(%BufferTarget{} = target), do: {:ok, BufferTarget.position(target)}

  defp validate_target(%TextTarget{} = target),
    do:
      Buffer.resolve_position_if_version(
        target.buffer,
        target.source_version,
        TextTarget.position(target)
      )

  @doc "Dispatches a mouse event routed to a focus-tree node."
  @spec handle_at_node(
          state(),
          FocusNode.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: state()
  def handle_at_node(
        state,
        %FocusNode{content_type: content_type, ref: win_id},
        row,
        col,
        button,
        mods,
        :press,
        click_count
      )
      when content_type in [:buffer_content, :agent_chat_window] and
             button in [:wheel_down, :wheel_up, :wheel_left, :wheel_right] do
    handle_buffer_scroll_at_window(state, win_id, row, col, button, mods, click_count)
  end

  def handle_at_node(state, _node, row, col, button, mods, event_type, click_count) do
    handle(state, row, col, button, mods, event_type, click_count)
  end

  @spec handle_scroll_batch(state(), non_neg_integer(), integer(), :down | :up) :: state()
  def handle_scroll_batch(state, _window_id, 0, _direction), do: state

  def handle_scroll_batch(state, window_id, delta_lines, direction) do
    apply_scroll_intent(state, window_id, delta_lines, direction)
  end

  # Shared entry point for wheel/trackpad scroll intent (#2661, corrected #2684),
  # used by both the smooth-trackpad accumulator (`handle_scroll_batch/4`) and the
  # discrete per-tick wheel path for inactive windows (`scroll_window_vertical/3`).
  #
  # Wheel/trackpad scrolling is VSCode-style: it moves only the viewport and never
  # the cursor, at any residence, distance, or velocity (#2684). The cursor may
  # leave the viewport; the next cursor-moving keypress re-anchors the view via the
  # existing cursor-follow. Explicit scroll commands (ctrl-e/ctrl-y, ctrl-d/u/f/b,
  # zz family) keep their vim cursor semantics — this path is mouse-wheel only.
  #
  # `Window.mark_scroll_echo/2` records the committed top of this move as a
  # frontend-reported free-scroll top so the render pipeline's
  # `Window.settle_scroll_seq/1` does not bump `scroll_seq` for it — only
  # BEAM-initiated jumps and the cursor-must-stay-visible re-attach do, which is
  # the "no re-anchor storm" contract from #2661. The echo top is sticky and
  # editor-owned (never written back), so the async render round trip cannot
  # latch or clobber it.
  @spec apply_scroll_intent(state(), non_neg_integer(), integer(), :down | :up) :: state()
  defp apply_scroll_intent(state, window_id, delta_lines, _direction) do
    case Map.fetch(state.workspace.windows.map, window_id) do
      {:ok, %Window{content: {:buffer, buf}} = window} when is_pid(buf) ->
        now = System.monotonic_time(:millisecond)
        total_lines = Buffer.line_count(buf)
        cursor_pos = Buffer.cursor(buf)

        scrolled = Window.scroll_viewport(window, delta_lines, total_lines)

        updated =
          scrolled
          |> Window.mark_scroll_echo(scrolled.viewport.top)
          |> Window.record_scroll_event(now, cursor_pos)

        %{
          state
          | workspace:
              MingaEditor.Session.State.set_windows(
                state.workspace,
                MingaEditor.State.Windows.replace_window(
                  state.workspace.windows,
                  window_id,
                  updated
                )
              )
        }

      _ ->
        state
    end
  end

  @spec native_gui?(state()) :: boolean()
  defp native_gui?(%{frontend: %{capabilities: %Capabilities{frontend_type: :native_gui}}}),
    do: true

  defp native_gui?(_state), do: false

  @doc "Dispatches a mouse event, returning updated state."
  @spec handle(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: state()

  # ── Left release ──

  def handle(
        %{workspace: %{mouse: %MouseState{drag: {:active, _}}, editing: %{mode: :visual}}} = state,
        _r,
        _c,
        :left,
        _m,
        :release,
        _cc
      ) do
    state
    |> update_mouse(&MouseState.stop_drag/1)
    |> auto_copy_selection()
  end

  def handle(
        %{workspace: %{mouse: %MouseState{drag: {:active, _}}}} = state,
        _r,
        _c,
        :left,
        _m,
        :release,
        _cc
      ) do
    update_mouse(state, &MouseState.stop_drag/1)
  end

  def handle(
        %{workspace: %{mouse: %MouseState{resize: {:active, _}}}} = state,
        _r,
        _c,
        :left,
        _m,
        :release,
        _cc
      ) do
    update_mouse(state, &MouseState.stop_resize/1)
  end

  # Ignore mouse events when no buffer is open.
  def handle(
        %{workspace: %{buffers: %{active: nil}}} = state,
        _row,
        _col,
        _button,
        _mods,
        _type,
        _cc
      ),
      do: state

  def handle(
        %{workspace: %{mouse: %MouseState{drag: {:active, _}}}} = state,
        row,
        col,
        :left,
        _mods,
        :drag,
        _cc
      ) do
    {:active, anchor, _origin_window, click_count} = MouseState.active_drag(state.workspace.mouse)
    handle_left_drag(state, row, col, anchor, click_count)
  end

  # Ignore negative coordinates except active drags, which clamp to the originating window edge.
  def handle(state, row, _col, _button, _mods, _type, _cc) when row < 0, do: state
  def handle(state, _row, col, _button, _mods, _type, _cc) when col < 0, do: state

  # ── Scroll wheel (vertical) ──

  def handle(
        %{workspace: %{buffers: %{active: buf}}} = state,
        _r,
        _c,
        :wheel_down,
        _m,
        :press,
        _cc
      ) do
    scroll_active_window_vertical(state, buf, scroll_lines(state), :down)
  end

  def handle(%{workspace: %{buffers: %{active: buf}}} = state, _r, _c, :wheel_up, _m, :press, _cc) do
    scroll_active_window_vertical(state, buf, -scroll_lines(state), :up)
  end

  # ── Scroll wheel (horizontal) ──

  def handle(state, _r, _c, :wheel_right, _m, :press, _cc) do
    vp = current_viewport(state)
    new_left = vp.left + scroll_cols(state)

    state
    |> update_current_viewport(%{vp | left: new_left})
    |> clamp_cursor_to_horizontal_viewport()
  end

  def handle(state, _r, _c, :wheel_left, _m, :press, _cc) do
    vp = current_viewport(state)
    new_left = max(vp.left - scroll_cols(state), 0)

    state
    |> update_current_viewport(%{vp | left: new_left})
    |> clamp_cursor_to_horizontal_viewport()
  end

  # ── Middle-click paste ──

  def handle(state, row, col, :middle, _mods, :press, _cc) do
    # Middle-click on tab bar closes the clicked tab
    case tab_bar_click(state, row, col) do
      {:command, _cmd} ->
        close_tab_at(state, row, col)

      :not_tab_bar ->
        case HitTest.resolve_buffer(state, row, col) do
          {:buffer, %BufferTarget{} = target} -> apply_middle_press(state, target)
          _command_or_miss -> state
        end
    end
  end

  # ── Left click (press) ──
  # Agent-region clicks are intercepted by Input.AgentMouse before
  # reaching this handler. This clause handles buffer-content clicks only.

  def handle(state, row, col, :left, mods, :press, cc) do
    handle_left_press(state, row, col, mods, cc)
  end

  # ── Right click (press) ──
  # Move the cursor for native GUI context menu commands without starting a selection drag.

  def handle(state, row, col, :right, _mods, :press, _cc) do
    handle_context_click(state, row, col)
  end

  # ── Left drag ──

  def handle(
        %{workspace: %{mouse: %MouseState{resize: {:active, {:vertical, sep_pos}}}}} = state,
        _row,
        col,
        :left,
        _mods,
        :drag,
        _cc
      ) do
    handle_separator_drag(state, :vertical, sep_pos, col)
  end

  def handle(
        %{workspace: %{mouse: %MouseState{resize: {:active, {:horizontal, sep_pos}}}}} = state,
        row,
        _col,
        :left,
        _mods,
        :drag,
        _cc
      ) do
    handle_separator_drag(state, :horizontal, sep_pos, row)
  end

  # ── Mouse motion (hover tracking + Cmd/Ctrl link preview) ──

  def handle(state, row, col, :none, mods, :motion, _cc) do
    handle_motion(state, row, col, mods)
  end

  # ── Ignore all other mouse events ──

  def handle(state, _row, _col, _button, _mods, _type, _cc), do: state

  # Free pointer motion. With the go-to-definition modifier held (Cmd/Super on
  # every frontend, or Ctrl on the TUI) the pointer previews a navigable symbol as
  # an underlined link (#2630); otherwise it drives normal hover tracking (#2629).
  # The link preview is computed locally (word boundaries + tree-sitter scope), so
  # it never sends a per-motion LSP request and cannot regress input latency.
  @spec handle_motion(state(), integer(), integer(), non_neg_integer()) :: state()
  defp handle_motion(state, row, col, mods) when band(mods, @mod_super) != 0 do
    update_cmd_hover_link(state, row, col)
  end

  # Ctrl on native GUI frontends follows platform context-menu semantics, so it
  # is not a link-preview modifier there; fall through to plain hover.
  defp handle_motion(
         %{frontend: %{capabilities: %Capabilities{frontend_type: :native_gui}}} = state,
         row,
         col,
         mods
       )
       when band(mods, @mod_ctrl) != 0 do
    clear_cmd_hover_link_then_hover(state, row, col)
  end

  # Ctrl on the TUI mirrors Ctrl+click go-to-definition, so it previews the link.
  defp handle_motion(state, row, col, mods) when band(mods, @mod_ctrl) != 0 do
    update_cmd_hover_link(state, row, col)
  end

  defp handle_motion(state, row, col, _mods) do
    clear_cmd_hover_link_then_hover(state, row, col)
  end

  # ── Cmd/Ctrl-hover link preview (#2630) ──────────────────────────────────────

  # Resolves the navigable symbol under the pointer and sets a transient link
  # decoration on its full word range, or clears it when there is nothing
  # navigable there. Intentionally leaves the hover popup and hover debounce
  # untouched: the link preview is an independent layer from the LSP hover popup.
  #
  # Hot-path guard (responsiveness epic): when the pointer cell is unchanged from
  # the previous resolved motion, the whole word-boundary + tree-sitter + buffer
  # snapshot resolution is skipped. Transitions that change the active buffer
  # reset `cmd_hover_cell` to nil, so a same-cell motion re-resolves afterwards.
  @spec update_cmd_hover_link(state(), integer(), integer()) :: state()
  defp update_cmd_hover_link(
         %{workspace: %{hover_observation: %{cell: {row, col}}}} = state,
         row,
         col
       ) do
    state
  end

  defp update_cmd_hover_link(state, row, col) do
    state = set_cmd_hover_link_if_changed(state, navigable_link_at(state, row, col))
    workspace = MingaEditor.Session.State.set_cmd_hover_cell(state.workspace, {row, col})
    %{state | workspace: workspace}
  end

  @spec set_cmd_hover_link_if_changed(state(), EditorState.cmd_hover_link()) :: state()
  defp set_cmd_hover_link_if_changed(
         %{workspace: %{hover_observation: %{link: link}}} = state,
         link
       ),
       do: state

  defp set_cmd_hover_link_if_changed(state, link) do
    %{state | workspace: MingaEditor.Session.State.set_cmd_hover_link(state.workspace, link)}
  end

  # Clears any standing link decoration (modifier released, or pointer moved off a
  # navigable symbol) before running normal hover tracking. Skips the clear write
  # when there is nothing to clear so plain motion stays allocation-free.
  @spec clear_cmd_hover_link_then_hover(state(), integer(), integer()) :: state()
  defp clear_cmd_hover_link_then_hover(
         %{workspace: %{hover_observation: %{link: nil, cell: nil}}} = state,
         row,
         col
       ) do
    handle_hover_motion(state, row, col)
  end

  defp clear_cmd_hover_link_then_hover(state, row, col) do
    workspace = MingaEditor.Session.State.clear_cmd_hover_link(state.workspace)
    state = %{state | workspace: workspace}
    handle_hover_motion(state, row, col)
  end

  # Returns the full word range `{start, end_exclusive}` for a navigable symbol at
  # the pointer, or nil. Navigable means: an identifier character sits under the
  # pointer, the position is not inside a comment or string (tree-sitter scope),
  # and an inner-word text object resolves. No LSP request is made.
  @spec navigable_link_at(state(), integer(), integer()) :: EditorState.cmd_hover_link()
  defp navigable_link_at(state, row, col) do
    case mouse_to_buffer_pos(state, row, col) do
      nil -> nil
      {line, buf_col} -> navigable_link_at_pos(state, line, buf_col)
    end
  end

  @spec navigable_link_at_pos(state(), non_neg_integer(), non_neg_integer()) ::
          EditorState.cmd_hover_link()
  defp navigable_link_at_pos(state, line, col) do
    buf = state.workspace.buffers.active

    with text when is_binary(text) <- cursor_line_text(buf, line),
         true <- identifier_char_at?(text, col),
         {{sl, sc}, {el, ec}} <- word_boundaries_at(buf, line, col),
         true <- navigable_scope?(state, buf, line, col) do
      {{sl, sc}, {el, Unicode.next_grapheme_byte_offset(text, ec)}}
    else
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  # True when the byte under `col` begins an identifier-class grapheme (ASCII word
  # char or any non-ASCII byte, which we treat as a Unicode letter). Punctuation,
  # whitespace, and line-end positions are not navigable.
  @spec identifier_char_at?(String.t(), non_neg_integer()) :: boolean()
  defp identifier_char_at?(text, col) when col >= byte_size(text), do: false

  defp identifier_char_at?(text, col) do
    case binary_part(text, col, 1) do
      <<c>> -> identifier_byte?(c)
      _ -> false
    end
  end

  @spec identifier_byte?(byte()) :: boolean()
  defp identifier_byte?(c) when c in ?a..?z, do: true
  defp identifier_byte?(c) when c in ?A..?Z, do: true
  defp identifier_byte?(c) when c in ?0..?9, do: true
  defp identifier_byte?(?_), do: true
  defp identifier_byte?(c) when c >= 128, do: true
  defp identifier_byte?(_), do: false

  # True when the tree-sitter scope at the position is code (not a comment or
  # string). When no highlight data exists yet (parser still loading, or a plain
  # buffer) the scope degrades to `:code`, matching `Highlight.scope_at/2`.
  @spec navigable_scope?(state(), pid(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp navigable_scope?(state, buf, line, col) do
    case Map.fetch(state.parser.highlighting.highlights, buf) do
      {:ok, %Highlight{} = hl} ->
        offset = Buffer.byte_offset_for_line(buf, line) + col
        Highlight.scope_at(hl, offset) == :code

      :error ->
        true
    end
  catch
    :exit, _ -> true
  end

  # Free pointer motion drives hover tracking. When a hover popup is open and the
  # pointer is inside its on-screen rect, the popup is kept alive untouched so the
  # user can read, scroll, or click it (#2629); restarting the debounce here would
  # thrash and dismissing it would defeat the point. Anywhere else, motion
  # (re)starts the hover debounce, dismissing a stale popup first.
  @spec handle_hover_motion(state(), integer(), integer()) :: state()
  defp handle_hover_motion(%{shell_runtime: %{state: %{hover_popup: nil}}} = state, row, col) do
    update_hover(state, row, col)
  end

  defp handle_hover_motion(state, row, col) do
    keep_or_dismiss_hover(state, row, col, SurfaceRegistry.within?(state, :hover_popup, row, col))
  end

  @spec keep_or_dismiss_hover(state(), integer(), integer(), boolean()) :: state()
  defp keep_or_dismiss_hover(state, _row, _col, true), do: state

  defp keep_or_dismiss_hover(state, row, col, false) do
    state
    |> MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss()
    |> update_hover(row, col)
  end

  @spec update_hover(state(), integer(), integer()) :: state()
  defp update_hover(state, row, col) do
    {mouse, previous_timer, schedule?} =
      MouseState.prepare_hover(
        state.workspace.mouse,
        row,
        col,
        backend: state.frontend.backend
      )

    cancel_timer(previous_timer)

    mouse =
      if schedule? do
        timer = Process.send_after(self(), :mouse_hover_timeout, MouseState.hover_delay_ms())
        MouseState.accept_hover_timer(mouse, timer)
      else
        mouse
      end

    update_mouse(state, fn _ -> mouse end)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  @spec update_mouse(state(), (MouseState.t() -> MouseState.t())) :: state()
  defp update_mouse(state, fun) when is_function(fun, 1) do
    %{
      state
      | workspace:
          MingaEditor.Session.State.set_mouse(state.workspace, fun.(state.workspace.mouse))
    }
  end

  @spec handle_left_drag(
          state(),
          integer(),
          integer(),
          {non_neg_integer(), non_neg_integer()},
          pos_integer()
        ) :: state()
  defp handle_left_drag(%{workspace: %{editing: %{mode: :visual}}} = state, row, col, anchor, dcc) do
    drag_to_mouse_pos(state, row, col, anchor, dcc)
  end

  defp handle_left_drag(state, row, col, anchor, dcc) do
    state = maybe_auto_scroll(state, row, col)

    case drag_mouse_to_buffer_pos(state, row, col) do
      nil -> state
      ^anchor -> state
      _target -> drag_to_mouse_pos_after_scroll(state, row, col, anchor, dcc)
    end
  end

  @spec drag_to_mouse_pos(
          state(),
          integer(),
          integer(),
          {non_neg_integer(), non_neg_integer()},
          pos_integer()
        ) :: state()
  defp drag_to_mouse_pos(state, row, col, anchor, dcc) do
    state
    |> maybe_auto_scroll(row, col)
    |> drag_to_mouse_pos_after_scroll(row, col, anchor, dcc)
  end

  @spec drag_to_mouse_pos_after_scroll(
          state(),
          integer(),
          integer(),
          {non_neg_integer(), non_neg_integer()},
          pos_integer()
        ) :: state()
  defp drag_to_mouse_pos_after_scroll(state, row, col, anchor, dcc) do
    case drag_mouse_to_buffer_pos(state, row, col) do
      nil ->
        state

      {line, byte} ->
        buffer = drag_selection_buffer(state)

        update_drag_selection(
          state,
          buffer,
          anchor,
          dcc,
          {line, byte},
          &move_buffer_position(buffer, &1)
        )
    end
  end

  @spec update_drag_selection(
          state(),
          pid(),
          text_position(),
          pos_integer(),
          text_position(),
          target_move()
        ) :: state()
  defp update_drag_selection(state, buffer, anchor, 2, target, move),
    do: snap_selection_to_words(state, buffer, anchor, target, move)

  defp update_drag_selection(state, buffer, anchor, 3, target, move),
    do: snap_selection_to_lines(state, buffer, anchor, target, move)

  defp update_drag_selection(state, _buffer, anchor, _click_count, target, move) do
    case move.(target) do
      {:ok, _position} -> enter_visual_if_needed(state, anchor)
      {:error, _reason} -> state
    end
  end

  @spec move_buffer_position(pid(), text_position()) ::
          {:ok, text_position()} | {:error, atom()}
  defp move_buffer_position(buffer, position) do
    :ok = Buffer.move_to(buffer, position)
    {:ok, position}
  end

  @spec handle_buffer_scroll_at_window(
          state(),
          term(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          pos_integer()
        ) :: state()
  defp handle_buffer_scroll_at_window(
         %{workspace: %{windows: %{active: win_id}}} = state,
         win_id,
         row,
         col,
         button,
         mods,
         click_count
       ) do
    handle(state, row, col, button, mods, :press, click_count)
  end

  defp handle_buffer_scroll_at_window(state, win_id, _row, _col, :wheel_down, _mods, _click_count) do
    scroll_window_vertical(state, win_id, scroll_lines(state))
  end

  defp handle_buffer_scroll_at_window(state, win_id, _row, _col, :wheel_up, _mods, _click_count) do
    scroll_window_vertical(state, win_id, -scroll_lines(state))
  end

  defp handle_buffer_scroll_at_window(
         state,
         win_id,
         _row,
         _col,
         :wheel_right,
         _mods,
         _click_count
       ) do
    scroll_window_horizontal(state, win_id, scroll_cols(state))
  end

  defp handle_buffer_scroll_at_window(state, win_id, _row, _col, :wheel_left, _mods, _click_count) do
    scroll_window_horizontal(state, win_id, -scroll_cols(state))
  end

  @spec scroll_window_vertical(state(), term(), integer()) :: state()
  defp scroll_window_vertical(state, win_id, delta) do
    dir = if delta > 0, do: :down, else: :up
    apply_scroll_intent(state, win_id, delta, dir)
  end

  @spec scroll_window_horizontal(state(), term(), integer()) :: state()
  defp scroll_window_horizontal(state, win_id, delta) do
    case Map.fetch(state.workspace.windows.map, win_id) do
      {:ok, %Window{}} ->
        %{
          state
          | workspace:
              MingaEditor.Session.State.set_windows(
                state.workspace,
                MingaEditor.State.Windows.scroll_horizontal(
                  state.workspace.windows,
                  win_id,
                  delta
                )
              )
        }

      _ ->
        state
    end
  end

  # Discrete physical-wheel scroll on the active window. A resident GUI window
  # free-scrolls through `apply_scroll_intent` (viewport-only + echo-mark, no
  # cursor drag per #2684), so the wheel never moves the cursor and the committed
  # top is marked as a scroll echo. Every non-GUI frontend and every non-resident
  # window keeps the viewport-only `scroll_viewport` path byte-identically, so
  # residence-off configs and the TUI are unchanged.
  @spec scroll_active_window_vertical(state(), pid(), integer(), :down | :up) :: state()
  defp scroll_active_window_vertical(state, buf, delta_lines, direction) do
    case active_resident_gui_window(state) do
      {:ok, win_id} ->
        apply_scroll_intent(state, win_id, delta_lines, direction)

      :error ->
        total_lines = Buffer.line_count(buf)
        vp = current_viewport(state)
        new_vp = scroll_viewport(vp, delta_lines, total_lines)
        update_current_viewport(state, new_vp)
    end
  end

  @spec active_resident_gui_window(state()) :: {:ok, Window.id()} | :error
  defp active_resident_gui_window(%{workspace: %{windows: %{active: win_id, map: map}}} = state) do
    with true <- native_gui?(state),
         {:ok, %Window{}} <- Map.fetch(map, win_id) do
      {:ok, win_id}
    else
      _ -> :error
    end
  end

  defp active_resident_gui_window(_state), do: :error

  # ── Left press dispatcher ──────────────────────────────────────────────────

  @spec handle_left_press(state(), integer(), integer(), non_neg_integer(), pos_integer()) ::
          state()
  defp handle_left_press(original, row, col, mods, native_click_count) do
    # Record press for multi-click detection
    mouse =
      MouseState.record_press_at(
        original.workspace.mouse,
        row,
        col,
        native_click_count,
        System.monotonic_time(:millisecond)
      )

    state = %{
      original
      | workspace: MingaEditor.Session.State.set_mouse(original.workspace, mouse)
    }

    click_count = MouseState.click_count(mouse)

    # Check modifier clicks first
    handle_left_press_modifiers(original, state, row, col, mods, click_count)
  end

  @spec handle_left_press_modifiers(
          state(),
          state(),
          integer(),
          integer(),
          non_neg_integer(),
          pos_integer()
        ) :: state()

  # Shift+click: extend selection
  defp handle_left_press_modifiers(_original, state, row, col, mods, _cc)
       when band(mods, @mod_shift) != 0 do
    handle_shift_click(state, row, col)
  end

  # Cmd+click (GUI) or Ctrl+click (TUI): go-to-definition.
  defp handle_left_press_modifiers(original, state, row, col, mods, _cc)
       when band(mods, @mod_super) != 0 do
    handle_goto_definition_click(original, state, row, col)
  end

  # On native GUI frontends, Ctrl-click follows platform context-menu semantics.
  defp handle_left_press_modifiers(
         _original,
         %{frontend: %{capabilities: %Capabilities{frontend_type: :native_gui}}} = state,
         row,
         col,
         mods,
         _cc
       )
       when band(mods, @mod_ctrl) != 0 do
    handle_context_click(state, row, col)
  end

  defp handle_left_press_modifiers(original, state, row, col, mods, _cc)
       when band(mods, @mod_ctrl) != 0 do
    handle_goto_definition_click(original, state, row, col)
  end

  # Double-click: reset split divider or select word
  defp handle_left_press_modifiers(_original, state, row, col, _mods, 2) do
    case reset_split_at_separator(state, row, col) do
      {:ok, reset_state} -> reset_state
      :error -> handle_double_click(state, row, col)
    end
  end

  # Triple-click: line selection
  defp handle_left_press_modifiers(_original, state, row, col, _mods, 3) do
    handle_triple_click(state, row, col)
  end

  # Single click: normal cursor positioning
  defp handle_left_press_modifiers(_original, state, row, col, _mods, _cc) do
    handle_plain_left_press(state, row, col)
  end

  @spec handle_plain_left_press(state(), integer(), integer()) :: state()
  defp handle_plain_left_press(state, row, col) do
    state
    |> maybe_start_separator_drag(row, col)
    |> maybe_handle_content_click(row, col)
  end

  # ── Double-click: word selection ───────────────────────────────────────────

  @spec handle_double_click(state(), integer(), integer()) :: state()
  defp handle_double_click(state, row, col) do
    case HitTest.resolve_buffer(state, row, col) do
      {:buffer, %BufferTarget{} = target} -> apply_double_click(state, target)
      _command_or_miss -> state
    end
  end

  # ── Triple-click: line selection ───────────────────────────────────────────

  @spec handle_triple_click(state(), integer(), integer()) :: state()
  defp handle_triple_click(state, row, col) do
    case HitTest.resolve_buffer(state, row, col) do
      {:buffer, %BufferTarget{} = target} -> apply_triple_click(state, target)
      _command_or_miss -> state
    end
  end

  # ── Shift+click: extend selection ──────────────────────────────────────────

  @spec handle_shift_click(state(), integer(), integer()) :: state()
  defp handle_shift_click(state, row, col) do
    case HitTest.resolve_buffer(state, row, col) do
      {:buffer, %BufferTarget{} = target} -> apply_shift_click(state, target)
      _command_or_miss -> state
    end
  end

  # ── Cmd/Ctrl+click: go-to-definition ───────────────────────────────────────

  @spec handle_goto_definition_click(state(), state(), integer(), integer()) :: state()
  defp handle_goto_definition_click(original, state, row, col) do
    case HitTest.resolve_buffer(state, row, col) do
      {:buffer, %BufferTarget{} = target} -> apply_goto_definition(original, state, target)
      _command_or_miss -> original
    end
  end

  @spec clear_cmd_hover_link_for_targeted_gesture(state()) :: state()
  defp clear_cmd_hover_link_for_targeted_gesture(state) do
    %{
      state
      | workspace: MingaEditor.Session.State.clear_cmd_hover_link(state.workspace)
    }
  end

  @spec normalize_mode_for_targeted_gesture(state()) :: state()
  defp normalize_mode_for_targeted_gesture(state) do
    state = cancel_mode_for_mouse(state)

    %{
      state
      | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :normal)
    }
  end

  # ── Word-by-word drag snapping ─────────────────────────────────────────────

  @spec snap_selection_to_words(
          state(),
          pid(),
          text_position(),
          text_position(),
          target_move()
        ) :: state()
  defp snap_selection_to_words(state, buffer, anchor, {line, byte} = target, move) do
    {anchor_line, anchor_byte} = anchor
    target_bounds = word_boundaries_at(buffer, line, byte)
    anchor_bounds = word_boundaries_at(buffer, anchor_line, anchor_byte)

    apply_word_drag(state, anchor, target, target_bounds, anchor_bounds, move)
  end

  @spec apply_word_drag(
          state(),
          text_position(),
          text_position(),
          {text_position(), text_position()} | nil,
          {text_position(), text_position()} | nil,
          target_move()
        ) :: state()
  defp apply_word_drag(
         state,
         anchor,
         target,
         {target_start, target_end},
         anchor_bounds,
         move
       ) do
    endpoint = if target >= anchor, do: target_end, else: target_start

    case move.(endpoint) do
      {:ok, _position} ->
        set_char_visual_selection(state, word_drag_anchor(target, anchor, anchor_bounds))

      {:error, _reason} ->
        state
    end
  end

  defp apply_word_drag(state, anchor, target, nil, {anchor_start, anchor_end}, move) do
    case move.(target) do
      {:ok, _position} ->
        set_char_visual_selection(
          state,
          word_drag_anchor(target, anchor, {anchor_start, anchor_end})
        )

      {:error, _reason} ->
        state
    end
  end

  defp apply_word_drag(state, anchor, target, _target_bounds, _anchor_bounds, move) do
    case move.(target) do
      {:ok, _position} -> enter_visual_if_needed(state, anchor)
      {:error, _reason} -> state
    end
  end

  @spec word_drag_anchor(
          text_position(),
          text_position(),
          {text_position(), text_position()} | nil
        ) :: text_position()
  defp word_drag_anchor(target, anchor, {anchor_start, _anchor_end}) when target >= anchor,
    do: anchor_start

  defp word_drag_anchor(_target, _anchor, {_anchor_start, anchor_end}), do: anchor_end
  defp word_drag_anchor(_target, anchor, nil), do: anchor

  # ── Line-by-line drag snapping ─────────────────────────────────────────────

  @spec snap_selection_to_lines(
          state(),
          pid(),
          text_position(),
          text_position(),
          target_move()
        ) :: state()
  defp snap_selection_to_lines(state, buffer, {anchor_line, _anchor_byte}, target, move) do
    endpoint = line_drag_endpoint(buffer, anchor_line, target)

    case move.(endpoint) do
      {:ok, _position} -> set_line_visual_selection(state, {anchor_line, 0})
      {:error, _reason} -> state
    end
  end

  @spec line_drag_endpoint(pid(), non_neg_integer(), text_position()) :: text_position()
  defp line_drag_endpoint(_buffer, anchor_line, {line, _byte}) when line < anchor_line,
    do: {line, 0}

  defp line_drag_endpoint(buffer, _anchor_line, {line, _byte}) do
    line_text = cursor_line_text(buffer, line)
    {line, max(byte_size(line_text) - 1, 0)}
  end

  @spec set_line_visual_selection(state(), text_position()) :: state()
  defp set_line_visual_selection(state, anchor) do
    visual_state = %VisualState{visual_anchor: anchor, visual_type: :line}

    %{
      state
      | workspace:
          MingaEditor.Session.State.transition_mode(state.workspace, :visual, visual_state)
    }
  end

  # ── Word boundary detection ────────────────────────────────────────────────

  @spec word_boundaries_at(pid(), non_neg_integer(), non_neg_integer()) ::
          {Minga.Editing.TextObject.position(), Minga.Editing.TextObject.position()} | nil
  defp word_boundaries_at(buf, line, col) do
    case Buffer.lines(buf, line, 1) do
      [text] when byte_size(text) > 0 ->
        buf
        |> Buffer.snapshot()
        |> Editing.select_inner_word({line, col})

      _ ->
        nil
    end
  end

  # ── Separator resize helpers ──────────────────────────────────────────────

  @spec maybe_start_separator_drag(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_start_separator_drag(%{workspace: %{windows: %{tree: nil}}} = state, _row, _col),
    do: state

  defp maybe_start_separator_drag(state, row, col) do
    screen = Layout.get(state).editor_area

    case WindowTree.separator_at(state.workspace.windows.tree, screen, row, col) do
      {:ok, {dir, sep_pos}} ->
        update_mouse(state, &MouseState.start_resize(&1, dir, sep_pos))

      :error ->
        state
    end
  end

  @spec maybe_handle_content_click(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_handle_content_click(
         %{workspace: %{mouse: %MouseState{resize: {:active, _}}}} = state,
         _row,
         _col
       ),
       do: state

  defp maybe_handle_content_click(state, row, col) do
    case tab_bar_click(state, row, col) do
      {:command, cmd} -> dispatch_tab_bar_command(state, cmd)
      :not_tab_bar -> handle_content_click(state, row, col)
    end
  end

  @spec dispatch_tab_bar_command(state(), tab_command()) :: state()
  defp dispatch_tab_bar_command(state, cmd) when is_tuple(cmd) do
    MingaEditor.dispatch_command(state, cmd)
  end

  defp dispatch_tab_bar_command(state, cmd) do
    case Atom.to_string(cmd) do
      "tab_close_" <> _ -> close_tab_by_command(state, cmd)
      _ -> MingaEditor.dispatch_command(state, cmd)
    end
  end

  @spec reset_split_at_separator(state(), non_neg_integer(), non_neg_integer()) ::
          {:ok, state()} | :error
  defp reset_split_at_separator(%{workspace: %{windows: %{tree: nil}}}, _row, _col), do: :error

  defp reset_split_at_separator(state, row, col) do
    screen = Layout.get(state).editor_area

    with {:ok, {_dir, _sep_pos}} <-
           WindowTree.separator_at(state.workspace.windows.tree, screen, row, col),
         {:ok, new_tree} <-
           WindowTree.reset_split_at_coordinate(state.workspace.windows.tree, screen, row, col) do
      windows = Windows.set_tree(state.workspace.windows, new_tree)

      state =
        %{state | workspace: MingaEditor.Session.State.set_windows(state.workspace, windows)}

      {:ok, resize_windows_to_layout(state)}
    end
  end

  @spec handle_separator_drag(state(), WindowTree.direction(), non_neg_integer(), integer()) ::
          state()
  defp handle_separator_drag(state, dir, sep_pos, new_pos) do
    screen = Layout.get(state).editor_area

    case WindowTree.resize_at(state.workspace.windows.tree, screen, dir, sep_pos, new_pos) do
      {:ok, new_tree} ->
        windows = Windows.set_tree(state.workspace.windows, new_tree)
        mouse = MouseState.update_resize(state.workspace.mouse, dir, new_pos)

        workspace =
          state.workspace
          |> MingaEditor.Session.State.set_windows(windows)
          |> MingaEditor.Session.State.set_mouse(mouse)

        resize_windows_to_layout(%{state | workspace: workspace})

      :error ->
        state
    end
  end

  @spec resize_windows_to_layout(state()) :: state()
  defp resize_windows_to_layout(state) do
    layout = Layout.get(state)

    Enum.reduce(layout.window_layouts, state, fn {id, wl}, acc ->
      {_r, _c, width, height} = wl.total

      %{
        acc
        | workspace:
            MingaEditor.Session.State.set_windows(
              acc.workspace,
              MingaEditor.State.Windows.resize(acc.workspace.windows, id, height, width)
            )
      }
    end)
  end

  @spec handle_content_click(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp handle_content_click(state, row, col) do
    state
    |> maybe_unfocus_file_tree_for_content_click()
    |> maybe_focus_window_at(row, col)
    |> handle_buffer_target_click(row, col)
  end

  @spec handle_buffer_target_click(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp handle_buffer_target_click(state, row, col) do
    case handle_block_command_click(state, row, col) do
      {:handled, state} -> state
      :miss -> handle_non_block_content_click(state, row, col)
    end
  end

  @spec handle_non_block_content_click(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp handle_non_block_content_click(state, row, col) do
    case handle_fold_gutter_click(state, row, col) do
      {:handled, state} -> state
      :miss -> handle_buffer_content_click(state, row, col)
    end
  end

  @spec handle_context_click(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp handle_context_click(state, row, col) do
    state = maybe_unfocus_file_tree_for_content_click(state)

    case HitTest.resolve_buffer(state, row, col) do
      {:buffer, %BufferTarget{} = target} -> apply_context_press(state, target)
      _command_or_miss -> state
    end
  end

  @spec click_inside_visual_selection?(state(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp click_inside_visual_selection?(
         %{
           workspace: %{
             editing: %{mode: :visual, mode_state: %VisualState{visual_type: :char} = mode_state},
             buffers: %{active: buf}
           }
         },
         target_line,
         target_col
       )
       when is_pid(buf) do
    {cursor_line, cursor_col} = Buffer.cursor(buf)
    {anchor_line, anchor_col} = mode_state.visual_anchor

    {start_pos, end_pos} =
      normalize_position_range({anchor_line, anchor_col}, {cursor_line, cursor_col})

    target_pos = {target_line, target_col}

    target_pos >= start_pos and target_pos <= end_pos
  end

  defp click_inside_visual_selection?(
         %{
           workspace: %{
             editing: %{mode: :visual, mode_state: %VisualState{visual_type: :line} = mode_state},
             buffers: %{active: buf}
           }
         },
         target_line,
         _target_col
       )
       when is_pid(buf) do
    {cursor_line, _cursor_col} = Buffer.cursor(buf)
    {anchor_line, _anchor_col} = mode_state.visual_anchor
    min_line = min(anchor_line, cursor_line)
    max_line = max(anchor_line, cursor_line)

    target_line >= min_line and target_line <= max_line
  end

  defp click_inside_visual_selection?(_state, _target_line, _target_col), do: false

  @spec normalize_position_range(
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()}
        ) :: {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}}
  defp normalize_position_range(first, second) when first <= second, do: {first, second}
  defp normalize_position_range(first, second), do: {second, first}

  @spec handle_block_command_click(state(), non_neg_integer(), non_neg_integer()) ::
          {:handled, state()} | :miss
  defp handle_block_command_click(state, row, col) do
    case HitTest.resolve_buffer(state, row, col) do
      {:command, command} -> {:handled, MingaEditor.dispatch_command(state, command)}
      :block_noop -> {:handled, state}
      _target_or_miss -> :miss
    end
  end

  @spec handle_buffer_content_click(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp handle_buffer_content_click(state, row, col) do
    case HitTest.resolve_buffer(state, row, col) do
      {:buffer, %BufferTarget{} = target} -> apply_plain_click(state, target)
      _command_or_miss -> state
    end
  end

  @spec handle_fold_gutter_click(state(), non_neg_integer(), non_neg_integer()) ::
          {:handled, state()} | :miss
  defp handle_fold_gutter_click(state, row, col) do
    case fold_gutter_click_target(state, row, col) do
      nil ->
        :miss

      {:window_fold, win_id, buf_line} ->
        {:handled,
         %{
           state
           | workspace:
               MingaEditor.Session.State.set_windows(
                 state.workspace,
                 MingaEditor.State.Windows.toggle_fold(state.workspace.windows, win_id, buf_line)
               )
         }}

      {:decoration_fold, buf, fold_id} ->
        toggle_decoration_fold(buf, fold_id)
        {:handled, state}
    end
  end

  @spec toggle_decoration_fold(pid(), reference()) :: :ok
  defp toggle_decoration_fold(buf, fold_id) do
    Buffer.batch_decorations(buf, fn decs -> Decorations.toggle_fold_region(decs, fold_id) end)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec fold_gutter_click_target(state(), non_neg_integer(), non_neg_integer()) ::
          fold_gutter_target() | nil
  defp fold_gutter_click_target(state, row, col) do
    layout = Layout.get(state)

    case Layout.active_window_layout(layout, state) do
      %{content: {win_row, win_col, content_w, win_h}} ->
        find_fold_gutter_click_target(state, row, col, win_row, win_col, content_w, win_h)

      nil ->
        nil
    end
  end

  @spec find_fold_gutter_click_target(
          state(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: fold_gutter_target() | nil
  defp find_fold_gutter_click_target(state, row, col, win_row, win_col, content_w, win_h) do
    local_row = row - win_row

    fold_col = win_col + Gutter.fold_column_offset()

    if col == fold_col and local_row >= 0 and local_row < win_h do
      active_fold_target_at_row(state, local_row, win_h, content_w)
    else
      nil
    end
  end

  @spec active_fold_target_at_row(state(), non_neg_integer(), pos_integer(), pos_integer()) ::
          fold_gutter_target() | nil
  defp active_fold_target_at_row(
         %{workspace: %{windows: %{active: win_id}}} = state,
         local_row,
         win_h,
         content_w
       ) do
    case MingaEditor.Session.State.active_window_struct(state.workspace) do
      %Window{content: {:buffer, buf}} = window ->
        total_lines = Buffer.line_count(buf)
        {cursor_line, _} = window.cursor
        scroll_top = HitTest.scroll_top(window, win_h, content_w, cursor_line, buf)

        case fold_target_line_at_row(
               buf,
               window,
               local_row,
               scroll_top,
               win_h,
               content_w,
               total_lines
             ) do
          nil -> nil
          {:window_fold, buf_line} -> {:window_fold, win_id, buf_line}
          {:decoration_fold, fold_id} -> {:decoration_fold, buf, fold_id}
        end

      _other ->
        nil
    end
  end

  @spec fold_target_line_at_row(
          pid(),
          Window.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: fold_row_target() | nil
  defp fold_target_line_at_row(buf, window, local_row, scroll_top, win_h, content_w, total_lines) do
    decs = Buffer.decorations(buf)

    first_buf_line = display_map_scroll_top(window, scroll_top)

    text_width = HitTest.content_text_width(buf, total_lines, content_w)

    case DisplayMap.compute(window.fold_map, decs, first_buf_line, win_h, total_lines, text_width) do
      nil ->
        direct_fold_target(window, local_row + scroll_top, total_lines)

      %DisplayMap{} = dm ->
        display_map_fold_target(window, dm, local_row)
    end
  catch
    :exit, _ -> nil
  end

  @spec display_map_scroll_top(Window.t(), non_neg_integer()) :: non_neg_integer()
  defp display_map_scroll_top(%Window{fold_map: %FoldMap{folds: []}}, scroll_top), do: scroll_top

  defp display_map_scroll_top(%Window{fold_map: fold_map}, scroll_top),
    do: FoldMap.visible_to_buffer(fold_map, scroll_top)

  @spec display_map_fold_target(Window.t(), DisplayMap.t(), non_neg_integer()) ::
          fold_row_target() | nil
  defp display_map_fold_target(window, dm, local_row) do
    case Enum.at(dm.entries, local_row) do
      {buf_line, {:fold_start, _}} -> {:window_fold, buf_line}
      {_buf_line, {:decoration_fold, %{id: fold_id}}} -> {:decoration_fold, fold_id}
      {buf_line, :normal} -> foldable_start_target(window, buf_line)
      _ -> nil
    end
  end

  @spec direct_fold_target(Window.t(), non_neg_integer(), non_neg_integer()) ::
          fold_row_target() | nil
  defp direct_fold_target(_window, target_line, total_lines) when target_line >= total_lines,
    do: nil

  defp direct_fold_target(window, target_line, _total_lines),
    do: foldable_start_target(window, target_line)

  @spec foldable_start_target(Window.t(), non_neg_integer()) :: fold_row_target() | nil
  defp foldable_start_target(window, buf_line) do
    if fold_indicator_line?(window, buf_line), do: {:window_fold, buf_line}, else: nil
  end

  @spec fold_indicator_line?(Window.t(), non_neg_integer()) :: boolean()
  defp fold_indicator_line?(%Window{fold_map: fold_map, fold_ranges: ranges}, buf_line) do
    FoldMap.fold_start?(fold_map, buf_line) or Enum.any?(ranges, &(&1.start_line == buf_line))
  end

  @spec maybe_unfocus_file_tree_for_content_click(state()) :: state()
  defp maybe_unfocus_file_tree_for_content_click(
         %{workspace: %{keymap_scope: :file_tree}} = state
       ) do
    file_tree = FileTreeState.unfocus(state.workspace.file_tree)

    workspace =
      state.workspace
      |> MingaEditor.Session.State.set_file_tree(file_tree)
      |> MingaEditor.Session.State.set_keymap_scope(:editor)

    %{state | workspace: workspace}
  end

  defp maybe_unfocus_file_tree_for_content_click(state), do: state

  @spec maybe_focus_window_at(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_focus_window_at(%{workspace: %{windows: %{tree: nil}}} = state, _row, _col),
    do: state

  defp maybe_focus_window_at(state, row, col) do
    screen = Layout.get(state).editor_area

    case WindowTree.window_at(state.workspace.windows.tree, screen, row, col) do
      {:ok, id, _rect} -> MingaEditor.WindowFocus.focus(state, id)
      :error -> state
    end
  end

  # ── Screen-to-buffer coordinate translation ────────────────────────────────

  @spec mouse_to_buffer_pos(state(), integer(), integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp mouse_to_buffer_pos(state, row, col) do
    case HitTest.resolve_buffer(state, row, col) do
      {:buffer, target} ->
        BufferTarget.position(target)

      _command_or_miss ->
        nil
    end
  end

  @spec drag_mouse_to_buffer_pos(state(), integer(), integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp drag_mouse_to_buffer_pos(state, row, col) do
    case drag_window_context(state) do
      nil -> mouse_to_buffer_pos_for_drag_fallback(state, row, col)
      context -> drag_mouse_to_buffer_pos(state, context, row, col)
    end
  end

  @spec mouse_to_buffer_pos_for_drag_fallback(state(), integer(), integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp mouse_to_buffer_pos_for_drag_fallback(_state, row, _col) when row < 0, do: nil
  defp mouse_to_buffer_pos_for_drag_fallback(_state, _row, col) when col < 0, do: nil

  defp mouse_to_buffer_pos_for_drag_fallback(state, row, col),
    do: mouse_to_buffer_pos(state, row, col)

  @spec drag_window_context(state()) :: drag_window_context() | nil
  defp drag_window_context(state) do
    layout = Layout.get(state)
    win_id = origin_window_for_drag(state.workspace.mouse, state.workspace.windows.active)

    with id when is_integer(id) <- win_id,
         %Window{content: {:buffer, buf}} = window <-
           Map.get(state.workspace.windows.map, id),
         %{content: {content_row, content_col, content_w, content_h}} <-
           Map.get(layout.window_layouts, id) do
      {id, window, buf, content_row, content_col, content_w, max(content_h, 1)}
    else
      _ -> nil
    end
  end

  @spec origin_window_for_drag(MouseState.t(), Window.id() | nil) :: Window.id() | nil
  defp origin_window_for_drag(mouse, fallback) do
    case MouseState.active_drag(mouse) do
      {:active, _anchor, nil, _click_count} -> fallback
      {:active, _anchor, origin_window, _click_count} -> origin_window
      :idle -> fallback
    end
  end

  @spec drag_mouse_to_buffer_pos(state(), drag_window_context(), integer(), integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp drag_mouse_to_buffer_pos(
         state,
         {_id, window, buf, content_row, content_col, content_w, content_h},
         row,
         col
       ) do
    total_lines = Buffer.line_count(buf)
    gutter_w = HitTest.buffer_gutter_width(buf, total_lines)
    {cursor_line, _} = window.cursor
    scroll_top = HitTest.scroll_top(window, content_h, content_w, cursor_line, buf)
    local_row = row - content_row
    visible_col = max(col - content_col - gutter_w, 0)
    display_col = visible_col + window.viewport.left

    if local_row < 0 or local_row >= content_h do
      resolve_drag_buffer_pos(buf, local_row, display_col, scroll_top, content_h, total_lines)
    else
      case HitTest.position(
             state,
             buf,
             window,
             local_row,
             visible_col,
             scroll_top,
             {content_h, content_w, total_lines}
           ) do
        {:position, pos} ->
          pos

        _target_or_miss ->
          resolve_drag_buffer_pos(buf, local_row, display_col, scroll_top, content_h, total_lines)
      end
    end
  catch
    :exit, _ -> nil
  end

  @spec resolve_drag_buffer_pos(
          pid(),
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: {non_neg_integer(), non_neg_integer()}
  defp resolve_drag_buffer_pos(buf, local_row, local_col, scroll_top, content_h, total_lines) do
    line = drag_target_line(local_row, scroll_top, content_h, total_lines)
    {line, HitTest.clamp_col_to_line(buf, line, local_col)}
  end

  @spec drag_target_line(integer(), non_neg_integer(), pos_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp drag_target_line(local_row, scroll_top, _content_h, total_lines) when local_row < 0 do
    min(scroll_top, total_lines - 1)
  end

  defp drag_target_line(local_row, scroll_top, content_h, total_lines)
       when local_row >= content_h do
    min(scroll_top + content_h - 1, total_lines - 1)
  end

  defp drag_target_line(local_row, scroll_top, _content_h, total_lines) do
    (scroll_top + local_row) |> max(0) |> min(total_lines - 1)
  end

  @spec auto_copy_selection(EditorState.t()) :: EditorState.t()
  defp auto_copy_selection(
         %{frontend: %{capabilities: %Capabilities{frontend_type: :native_gui}}} = state
       ),
       do: state

  defp auto_copy_selection(
         %{workspace: %{editing: %{mode: :visual, mode_state: ms}, buffers: %{active: buf}}} =
           state
       )
       when is_pid(buf) do
    text = selection_text(buf, ms)
    maybe_copy_to_clipboard(state, text)
    state
  catch
    :exit, _ -> state
  end

  defp auto_copy_selection(state), do: state

  @spec selection_text(pid(), map()) :: String.t() | nil
  defp selection_text(buf, %{visual_type: :char} = ms) do
    Buffer.text_between_inclusive(buf, ms.visual_anchor, Buffer.cursor(buf))
  end

  defp selection_text(buf, %{visual_type: :line} = ms) do
    {a_line, _} = ms.visual_anchor
    {c_line, _} = Buffer.cursor(buf)
    Buffer.content_on_lines(buf, min(a_line, c_line), max(a_line, c_line))
  end

  defp maybe_copy_to_clipboard(%{workspace: %{buffers: %{active: buf}}}, text)
       when is_pid(buf) and is_binary(text) and text != "" do
    case Buffer.get_option(buf, :clipboard) do
      :none -> :ok
      _ -> Minga.Clipboard.write(text)
    end
  end

  defp maybe_copy_to_clipboard(_state, _text), do: :ok

  # ── Viewport helpers ───────────────────────────────────────────────────────

  @spec scroll_viewport(Viewport.t(), integer(), non_neg_integer()) :: Viewport.t()
  defp scroll_viewport(%Viewport{} = vp, delta, total_lines) do
    visible_rows = Viewport.content_rows(vp)
    max_top = max(0, total_lines - visible_rows)
    new_top = (vp.top + delta) |> max(0) |> min(max_top)
    Viewport.put_top(vp, new_top)
  end

  @spec clamp_cursor_to_horizontal_viewport(state()) :: state()
  defp clamp_cursor_to_horizontal_viewport(%{workspace: %{buffers: %{active: buf}}} = state)
       when is_pid(buf) do
    vp = current_viewport(state)
    {line, byte_col} = Buffer.cursor(buf)
    line_text = cursor_line_text(buf, line)
    display_col = Unicode.display_col(line_text, byte_col)
    target_col = horizontal_cursor_target(display_col, vp.left, vp.cols)

    if target_col == display_col do
      state
    else
      Buffer.move_to(buf, {line, byte_offset_for_visible_col(line_text, target_col)})
      state
    end
  catch
    :exit, _ -> state
  end

  defp clamp_cursor_to_horizontal_viewport(state), do: state

  @spec horizontal_cursor_target(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  defp horizontal_cursor_target(display_col, left, _cols) when display_col < left, do: left

  defp horizontal_cursor_target(display_col, left, cols) when display_col >= left + cols do
    left + cols - 1
  end

  defp horizontal_cursor_target(display_col, _left, _cols), do: display_col

  @spec byte_offset_for_visible_col(String.t(), non_neg_integer()) :: non_neg_integer()
  defp byte_offset_for_visible_col(line_text, target_col) do
    line_text
    |> Unicode.display_col_to_byte(target_col)
    |> advance_to_visible_col(line_text, target_col)
  end

  @spec advance_to_visible_col(non_neg_integer(), String.t(), non_neg_integer()) ::
          non_neg_integer()
  defp advance_to_visible_col(byte_col, line_text, target_col) do
    display_col = Unicode.display_col(line_text, byte_col)

    if display_col >= target_col or byte_col >= byte_size(line_text) do
      byte_col
    else
      line_text
      |> Unicode.next_grapheme_byte_offset(byte_col)
      |> advance_to_visible_col(line_text, target_col)
    end
  end

  @spec cursor_line_text(pid(), non_neg_integer()) :: String.t()
  defp cursor_line_text(buf, line) do
    case Buffer.lines(buf, line, 1) do
      [text] -> text
      _ -> ""
    end
  end

  @spec maybe_auto_scroll(state(), integer(), integer()) :: state()
  defp maybe_auto_scroll(state, row, col) do
    case drag_window_context(state) do
      nil ->
        state

      context ->
        state
        |> maybe_auto_scroll_vertical(context, row)
        |> maybe_auto_scroll_horizontal(context, col)
    end
  end

  @spec maybe_auto_scroll_vertical(state(), drag_window_context(), integer()) :: state()
  defp maybe_auto_scroll_vertical(
         state,
         {win_id, _window, _buf, content_row, _content_col, _w, _h},
         row
       )
       when row < content_row do
    scroll_window_vertical(state, win_id, -1)
  end

  defp maybe_auto_scroll_vertical(
         state,
         {win_id, _window, _buf, content_row, _content_col, _w, content_h},
         row
       )
       when row >= content_row + content_h do
    scroll_window_vertical(state, win_id, 1)
  end

  defp maybe_auto_scroll_vertical(state, _context, _row), do: state

  @spec maybe_auto_scroll_horizontal(state(), drag_window_context(), integer()) :: state()
  defp maybe_auto_scroll_horizontal(
         state,
         {win_id, _window, _buf, _row, content_col, _w, _h},
         col
       )
       when col < content_col do
    scroll_window_horizontal(state, win_id, -scroll_cols(state))
  end

  defp maybe_auto_scroll_horizontal(
         state,
         {win_id, _window, _buf, _row, content_col, content_w, _h},
         col
       )
       when col >= content_col + content_w do
    scroll_window_horizontal(state, win_id, scroll_cols(state))
  end

  defp maybe_auto_scroll_horizontal(state, _context, _col), do: state

  @spec drag_selection_buffer(state()) :: pid()
  defp drag_selection_buffer(state) do
    case drag_window_context(state) do
      {_window_id, _window, buffer, _row, _col, _width, _height} -> buffer
      nil -> state.workspace.buffers.active
    end
  end

  @spec enter_visual_if_needed(state(), {non_neg_integer(), non_neg_integer()}) :: state()
  defp enter_visual_if_needed(%{workspace: %{editing: %{mode: :visual}}} = state, _anchor),
    do: state

  defp enter_visual_if_needed(state, anchor), do: set_char_visual_selection(state, anchor)

  @spec set_char_visual_selection(state(), {non_neg_integer(), non_neg_integer()}) :: state()
  defp set_char_visual_selection(state, anchor) do
    visual_state = %VisualState{visual_anchor: anchor, visual_type: :char}

    %{
      state
      | workspace:
          MingaEditor.Session.State.transition_mode(state.workspace, :visual, visual_state)
    }
  end

  @spec cancel_mode_for_mouse(state()) :: state()
  defp cancel_mode_for_mouse(%{workspace: %{editing: %{mode: :command}}} = state) do
    MingaEditor.Shell.Traditional.WhichKeyWorkflow.dismiss(state)
  end

  defp cancel_mode_for_mouse(state), do: state

  # ── Tab bar close (middle-click) ─────────────────────────────────────────

  @spec close_tab_at(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp close_tab_at(state, row, col) do
    case tab_bar_command_at(state, row, col) do
      nil -> state
      command -> close_tab_by_command(state, command)
    end
  end

  @spec close_tab_by_command(state(), tab_command()) :: state()
  defp close_tab_by_command(state, cmd) do
    case parse_tab_id(cmd) do
      {:ok, tab_id} ->
        state = MingaEditor.TabWorkflow.switch(state, tab_id)
        MingaEditor.dispatch_command(state, :kill_buffer)

      :error ->
        state
    end
  end

  @spec parse_tab_id(tab_command()) :: {:ok, pos_integer()} | :error
  defp parse_tab_id({:tab_goto_id, tab_id}) when is_integer(tab_id) and tab_id > 0 do
    {:ok, tab_id}
  end

  defp parse_tab_id(cmd) when is_atom(cmd) do
    case Atom.to_string(cmd) do
      "tab_goto_" <> id_str ->
        case Integer.parse(id_str) do
          {tab_id, ""} when tab_id > 0 -> {:ok, tab_id}
          _ -> :error
        end

      "tab_close_" <> id_str ->
        case Integer.parse(id_str) do
          {tab_id, ""} when tab_id > 0 -> {:ok, tab_id}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_tab_id(_cmd), do: :error

  # ── Tab bar click detection ──────────────────────────────────────────────

  # The tab-bar *surface rect* comes from the surface registry (the single
  # source for "what is where on screen"); the per-tab *segment* command lookup
  # stays here because segments are render-time text-property spans, not placed
  # surfaces. See `MingaEditor.Layout.SurfaceRegistry` moduledoc.
  @spec tab_bar_click(state(), non_neg_integer(), non_neg_integer()) ::
          {:command, tab_command()} | :not_tab_bar
  defp tab_bar_click(state, row, col) do
    if SurfaceRegistry.within?(state, :tab_bar, row, col) do
      case tab_bar_command_at(state, row, col) do
        nil -> :not_tab_bar
        command -> {:command, command}
      end
    else
      :not_tab_bar
    end
  end

  @spec tab_bar_command_at(state(), non_neg_integer(), non_neg_integer()) :: tab_command() | nil
  defp tab_bar_command_at(
         %{shell_runtime: %{state: %TraditionalState{} = shell_state}},
         row,
         col
       ),
       do: TraditionalState.tab_bar_command_at(shell_state, row, col)

  defp tab_bar_command_at(_state, _row, _col), do: nil

  # GUI frontends accumulate pixel deltas and emit one scroll event per
  # line height crossed, so each event = 1 line. TUI frontends send one
  # event per wheel tick, so each event = 3 lines for usable speed.
  @spec scroll_lines(state()) :: pos_integer()
  defp scroll_lines(%{frontend: %{capabilities: %Capabilities{frontend_type: :native_gui}}}),
    do: @gui_scroll_lines

  defp scroll_lines(_state) do
    Config.get(:scroll_lines)
  catch
    :exit, _ -> 1
  end

  @spec scroll_cols(state()) :: pos_integer()
  defp scroll_cols(%{frontend: %{capabilities: %Capabilities{frontend_type: :native_gui}}}),
    do: @gui_scroll_cols

  defp scroll_cols(_state), do: @scroll_cols

  # Delegates to EditorState shared helpers.
  defp current_viewport(state),
    do:
      MingaEditor.Session.State.current_viewport(
        state.workspace,
        state.frontend.terminal_viewport
      )

  defp update_current_viewport(state, new_vp),
    do: %{
      state
      | workspace: MingaEditor.Session.State.update_current_viewport(state.workspace, new_vp)
    }
end
