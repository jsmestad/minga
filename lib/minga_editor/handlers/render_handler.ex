defmodule MingaEditor.Handlers.RenderHandler do
  @moduledoc """
  Handler for render scheduling, nav-flash, yank-flash, and warning-popup events.

  Extracts the `handle_info` clauses for `:debounced_render`, `{:render_done, _}`,
  `:nav_flash_step`, `:yank_flash_step`, and `:warning_popup_timeout` from the
  Editor GenServer into public functions. The Editor delegates to this module
  via one-liner `handle_info` clauses.

  Unlike the pure `{state, [effect]}` handlers, this module returns `state`
  directly because render and flash operations apply their side effects inline
  (timers, buffer highlights, renderer calls).
  """

  alias Minga.Buffer
  alias Minga.Config

  alias MingaEditor.BottomPanel
  alias MingaEditor.FlashEffects
  alias MingaEditor.NavFlash
  alias MingaEditor.Renderer
  alias MingaEditor.YankFlash

  alias MingaEditor.State, as: EditorState

  @typedoc "Editor state (re-exported for brevity)."
  @type state :: EditorState.t()

  # ── Handle_info delegates ──────────────────────────────────────────────

  @doc """
  Handles the `:debounced_render` timer firing.

  Triggers nav-flash detection, performs the render, and clears the timer ref.
  """
  @spec handle_debounced_render(state()) :: state()
  def handle_debounced_render(state) do
    state = maybe_trigger_nav_flash(state)
    state = Renderer.render_or_async(state)
    %{state | render_timer: nil}
  end

  @doc """
  Handles renderer writeback after an async frame completes.

  Narrows the merge to renderer-owned fields only.
  """
  @spec handle_render_done(state(), map()) :: state()
  def handle_render_done(state, writeback) do
    EditorState.apply_renderer_writeback(state, writeback)
  end

  @doc """
  Handles the `:nav_flash_step` timer, advancing the fade or clearing the flash.
  """
  @spec handle_nav_flash_step(state()) :: state()
  def handle_nav_flash_step(%{shell_state: %{nav_flash: nil}} = state), do: state

  def handle_nav_flash_step(state) do
    flash = state.shell_state.nav_flash

    case NavFlash.advance(flash) do
      {:continue, updated, effects} ->
        state = EditorState.set_nav_flash(state, apply_flash_effects(state, updated, effects))
        Renderer.render_or_async(state)

      :done ->
        Renderer.render_or_async(EditorState.cancel_nav_flash(state))
    end
  end

  @doc """
  Handles the `:yank_flash_step` timer, advancing the fade or clearing the flash.
  """
  @spec handle_yank_flash_step(state()) :: state()
  def handle_yank_flash_step(%{shell_state: %{yank_flash: nil}} = state), do: state

  def handle_yank_flash_step(state) do
    %YankFlash{buf: buf} = flash = state.shell_state.yank_flash

    case YankFlash.advance(flash) do
      {:continue, updated, effects} ->
        update_yank_flash_decoration(buf, updated, state)
        updated = apply_flash_effects(state, updated, effects)
        state = EditorState.set_yank_flash(state, updated)
        Renderer.render_or_async(state)

      :done ->
        clear_yank_highlight(buf)
        Renderer.render_or_async(EditorState.cancel_yank_flash(state))
    end
  end

  @doc """
  Handles the `:warning_popup_timeout` timer, opening the bottom panel if needed.
  """
  @spec handle_warning_popup_timeout(state()) :: state()
  def handle_warning_popup_timeout(state) do
    state = EditorState.update_shell_state(state, &%{&1 | warning_popup_timer: nil})
    open_warnings_popup_if_needed(state)
  end

  # ── Nav-flash detection (called from schedule_render and handle_debounced_render) ──

  @doc """
  Checks if the cursor jumped far enough to trigger a nav-flash.

  Updates `last_cursor_line` and, when the threshold is exceeded,
  starts (or restarts) the flash animation.
  """
  @spec maybe_trigger_nav_flash(state()) :: state()
  def maybe_trigger_nav_flash(%{workspace: %{buffers: %{active: nil}}} = state), do: state

  def maybe_trigger_nav_flash(state) do
    buf = state.workspace.buffers.active
    {current_line, _col} = Buffer.cursor(buf)

    state = detect_jump(state, current_line)
    %{state | last_cursor_line: current_line}
  end

  # ── Private helpers ────────────────────────────────────────────────────

  @spec detect_jump(state(), non_neg_integer()) :: state()
  defp detect_jump(%{last_cursor_line: nil} = state, _current_line), do: state

  defp detect_jump(state, current_line) do
    delta = abs(current_line - state.last_cursor_line)
    threshold = Config.get(:nav_flash_threshold)

    if delta >= threshold and Config.get(:nav_flash) do
      start_flash(state, current_line)
    else
      cancel_flash_if_active(state)
    end
  end

  @spec start_flash(state(), non_neg_integer()) :: state()
  defp start_flash(state, line) do
    flash = EditorState.nav_flash(state)
    old_timer = if flash, do: flash.timer, else: nil
    {new_flash, effects} = NavFlash.start(line, old_timer)
    EditorState.set_nav_flash(state, apply_flash_effects(state, new_flash, effects))
  end

  @spec cancel_flash_if_active(state()) :: state()
  defp cancel_flash_if_active(%{shell_state: %{nav_flash: nil}} = state), do: state

  defp cancel_flash_if_active(state) do
    effects = NavFlash.cancel_effects(EditorState.nav_flash(state))
    execute_flash_effects(state, effects)
    EditorState.cancel_nav_flash(state)
  end

  @spec update_yank_flash_decoration(pid(), YankFlash.t(), state()) :: :ok
  defp update_yank_flash_decoration(buf, flash, state) do
    flash_bg = state.theme.editor.yank_flash_bg || YankFlash.default_flash_bg()
    target_bg = state.theme.editor.bg
    color = YankFlash.color_for_step(flash, flash_bg, target_bg)

    {hl_start, hl_end} =
      YankFlash.highlight_bounds(buf, flash.start_pos, flash.end_pos, flash.range_type)

    try do
      Buffer.remove_highlight_group(buf, YankFlash.flash_group())

      Buffer.add_highlight(buf, hl_start, hl_end,
        style: Minga.Core.Face.new(bg: color),
        group: YankFlash.flash_group(),
        priority: 50
      )
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @spec clear_yank_highlight(pid()) :: :ok
  defp clear_yank_highlight(buf) do
    try do
      Buffer.remove_highlight_group(buf, YankFlash.flash_group())
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @spec apply_flash_effects(state(), struct(), [FlashEffects.side_effect()]) :: struct()
  defp apply_flash_effects(state, flash, effects) do
    FlashEffects.apply(state, flash, effects)
  end

  @spec execute_flash_effects(state(), [FlashEffects.side_effect()]) :: :ok
  defp execute_flash_effects(state, effects) do
    FlashEffects.execute(state, effects)
  end

  @spec open_warnings_popup_if_needed(state()) :: state()
  defp open_warnings_popup_if_needed(%{shell_state: %{bottom_panel: %{dismissed: true}}} = state),
    do: state

  defp open_warnings_popup_if_needed(
         %{shell_state: %{bottom_panel: %{visible: true, active_tab: :messages}}} = state
       ) do
    # Panel already visible on Messages tab; don't change the user's filter.
    MingaEditor.schedule_render(state, 16)
  end

  defp open_warnings_popup_if_needed(state) do
    # Auto-open the bottom panel with warnings filter preset
    new_panel = BottomPanel.show(EditorState.bottom_panel(state), :messages, :warnings)
    MingaEditor.schedule_render(EditorState.set_bottom_panel(state, new_panel), 16)
  end
end
