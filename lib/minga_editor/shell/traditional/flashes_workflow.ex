defmodule MingaEditor.Shell.Traditional.FlashesWorkflow do
  @moduledoc "Effectful timer, rendering, and decoration workflow for independent flashes."

  alias Minga.Buffer
  alias Minga.Core.Face
  alias MingaEditor.Renderer
  alias MingaEditor.Shell.Traditional.NavFlash
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.Shell.Traditional.YankFlash
  alias MingaEditor.State, as: EditorState

  @doc "Starts or replaces only the navigation flash."
  @spec replace_nav(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def replace_nav(
        %{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state,
        line
      ) do
    cancel_timer(state.shell_runtime.state.flashes.nav.timer)
    state = EditorState.update_shell_state(state, &ShellState.replace_nav_flash(&1, line))
    generation = state.shell_runtime.state.flashes.nav.generation
    schedule_nav(state, generation)
  end

  def replace_nav(state, _line), do: state

  @doc "Cancels only the navigation flash."
  @spec cancel_nav(EditorState.t()) :: EditorState.t()
  def cancel_nav(%{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state) do
    cancel_timer(state.shell_runtime.state.flashes.nav.timer)
    EditorState.update_shell_state(state, &ShellState.cancel_nav_flash/1)
  end

  def cancel_nav(state), do: state

  @doc "Advances a matching navigation generation and rejects stale delivery."
  @spec advance_nav(EditorState.t(), NavFlash.generation()) :: EditorState.t()
  def advance_nav(
        %{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state,
        generation
      ) do
    {result, shell_state} = ShellState.advance_nav_flash(state.shell_runtime.state, generation)
    state = EditorState.update_shell_state(state, fn _ -> shell_state end)

    case result do
      :continue -> state |> schedule_nav(generation) |> Renderer.render_or_async()
      :done -> Renderer.render_or_async(state)
      :stale -> state
    end
  end

  def advance_nav(state, _generation), do: state

  @doc "Starts or replaces only the yank flash and its decoration."
  @spec replace_yank(
          EditorState.t(),
          pid(),
          YankFlash.position(),
          YankFlash.position(),
          YankFlash.range_type()
        ) :: EditorState.t()
  def replace_yank(
        %{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state,
        buf,
        start_pos,
        end_pos,
        range_type
      ) do
    old = state.shell_runtime.state.flashes.yank
    cancel_timer(old.timer)
    clear_yank_highlight(old.buf)

    state =
      EditorState.update_shell_state(
        state,
        &ShellState.replace_yank_flash(&1, buf, start_pos, end_pos, range_type)
      )

    flash = state.shell_runtime.state.flashes.yank
    update_yank_decoration(flash, state)
    schedule_yank(state, flash.generation)
  end

  def replace_yank(state, _buf, _start_pos, _end_pos, _range_type), do: state

  @doc "Cancels only the yank flash and removes its decoration."
  @spec cancel_yank(EditorState.t()) :: EditorState.t()
  def cancel_yank(%{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state) do
    flash = state.shell_runtime.state.flashes.yank
    cancel_timer(flash.timer)
    clear_yank_highlight(flash.buf)
    EditorState.update_shell_state(state, &ShellState.cancel_yank_flash/1)
  end

  def cancel_yank(state), do: state

  @doc "Advances a matching yank generation and rejects stale delivery."
  @spec advance_yank(EditorState.t(), YankFlash.generation()) :: EditorState.t()
  def advance_yank(
        %{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state,
        generation
      ) do
    previous = state.shell_runtime.state.flashes.yank
    {result, shell_state} = ShellState.advance_yank_flash(state.shell_runtime.state, generation)
    state = EditorState.update_shell_state(state, fn _ -> shell_state end)

    case result do
      :continue ->
        update_yank_decoration(state.shell_runtime.state.flashes.yank, state)
        state |> schedule_yank(generation) |> Renderer.render_or_async()

      :done ->
        clear_yank_highlight(previous.buf)
        Renderer.render_or_async(state)

      :stale ->
        state
    end
  end

  def advance_yank(state, _generation), do: state

  @spec schedule_nav(EditorState.t(), NavFlash.generation()) :: EditorState.t()
  defp schedule_nav(%{backend: :headless} = state, _generation), do: state

  defp schedule_nav(state, generation) do
    timer = Process.send_after(self(), {:nav_flash_step, generation}, NavFlash.step_interval_ms())

    EditorState.update_shell_state(
      state,
      &ShellState.record_nav_flash_timer(&1, generation, timer)
    )
  end

  @spec schedule_yank(EditorState.t(), YankFlash.generation()) :: EditorState.t()
  defp schedule_yank(%{backend: :headless} = state, _generation), do: state

  defp schedule_yank(state, generation) do
    timer =
      Process.send_after(self(), {:yank_flash_step, generation}, YankFlash.step_interval_ms())

    EditorState.update_shell_state(
      state,
      &ShellState.record_yank_flash_timer(&1, generation, timer)
    )
  end

  @spec update_yank_decoration(YankFlash.t(), EditorState.t()) :: :ok
  defp update_yank_decoration(%YankFlash{buf: buf} = flash, state) when is_pid(buf) do
    flash_bg = state.theme.editor.yank_flash_bg || YankFlash.default_flash_bg()
    color = YankFlash.color_for_step(flash, flash_bg, state.theme.editor.bg)

    end_line_length = yank_end_line_length(buf, flash.end_pos, flash.range_type)

    {highlight_start, highlight_end} =
      YankFlash.highlight_bounds(
        flash.start_pos,
        flash.end_pos,
        flash.range_type,
        end_line_length
      )

    try do
      Buffer.remove_highlight_group(buf, YankFlash.flash_group())

      Buffer.add_highlight(buf, highlight_start, highlight_end,
        style: Face.new(bg: color),
        group: YankFlash.flash_group(),
        priority: 50
      )
    catch
      :exit, _reason -> :ok
    end

    :ok
  end

  defp update_yank_decoration(%YankFlash{}, _state), do: :ok

  @spec yank_end_line_length(pid(), YankFlash.position(), YankFlash.range_type()) ::
          non_neg_integer()
  defp yank_end_line_length(_buf, _end_pos, :charwise), do: 0

  defp yank_end_line_length(buf, {end_line, _}, :linewise) do
    case Buffer.lines(buf, end_line, 1) do
      [text] -> String.length(text)
      _other -> 0
    end
  catch
    :exit, _reason -> 0
  end

  @spec clear_yank_highlight(pid() | nil) :: :ok
  defp clear_yank_highlight(nil), do: :ok

  defp clear_yank_highlight(buf) do
    try do
      Buffer.remove_highlight_group(buf, YankFlash.flash_group())
    catch
      :exit, _reason -> :ok
    end

    :ok
  end

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end
end
