defmodule MingaEditor.Handlers.RenderHandler do
  @moduledoc "Focused render scheduling handler with navigation-flash observation."

  alias Minga.Buffer
  alias Minga.Config
  alias Minga.Telemetry
  alias MingaEditor.Renderer
  alias MingaEditor.Shell.Workflow
  alias MingaEditor.Shell.Traditional.FlashesWorkflow
  alias MingaEditor.State, as: EditorState

  @type state :: EditorState.t()

  @doc "Handles a matching debounced render delivery and rejects stale timer identities."
  @spec handle_debounced_render(
          state(),
          MingaEditor.State.RenderCorrelation.timer_identity()
        ) :: state()
  def handle_debounced_render(state, timer_identity) do
    case MingaEditor.State.RenderCorrelation.deliver(
           state.render.render_correlation,
           timer_identity
         ) do
      {:current, correlation} ->
        state = %{
          state
          | render: MingaEditor.State.Render.accept_correlation(state.render, correlation)
        }

        state
        |> maybe_trigger_nav_flash()
        |> Renderer.render_or_async()

      {:stale, _correlation} ->
        state
    end
  end

  @doc """
  Handles renderer writeback after an async frame completes.

  Narrows the merge to renderer-owned fields only.
  """
  @spec handle_render_done(state(), MingaEditor.Renderer.RenderReceipt.t()) :: state()
  def handle_render_done(state, receipt) do
    emit_render_done_hop(receipt)
    state = Workflow.ensure_available(state)
    {state, result} = EditorState.integrate_renderer_receipt(state, receipt)
    log_receipt_result(result, state, receipt)
    state
  end

  @spec log_receipt_result(
          EditorState.render_receipt_result(),
          state(),
          MingaEditor.Renderer.RenderReceipt.t()
        ) :: :ok
  defp log_receipt_result(:applied, _state, _receipt), do: :ok

  defp log_receipt_result({:stale, reason}, state, receipt) do
    Minga.Log.debug(:render, fn ->
      "Dropping stale renderer receipt reason=#{reason} frame=#{receipt.frame_seq} shell=#{inspect(receipt.shell_id)} identity=#{inspect(receipt.shell_identity)} active_shell=#{inspect(MingaEditor.Shell.Runtime.id(state.shell_runtime))}"
    end)
  end

  @doc "Observes cursor movement and replaces or cancels the navigation flash."
  @spec maybe_trigger_nav_flash(state()) :: state()
  def maybe_trigger_nav_flash(%{workspace: %{buffers: %{active: nil}}} = state), do: state

  def maybe_trigger_nav_flash(state) do
    {current_line, _col} = Buffer.cursor(state.workspace.buffers.active)
    state = detect_jump(state, current_line)
    %{state | render: MingaEditor.State.Render.observe_cursor_line(state.render, current_line)}
  end

  @spec emit_render_done_hop(map()) :: :ok
  defp emit_render_done_hop(%{render_sent_at: sent_at}),
    do: Telemetry.hop_latency(:render_done, sent_at)

  defp emit_render_done_hop(_writeback), do: :ok

  @spec detect_jump(state(), non_neg_integer()) :: state()
  defp detect_jump(%{render: %{last_cursor_line: nil}} = state, _current_line), do: state

  defp detect_jump(state, current_line) do
    delta = abs(current_line - state.render.last_cursor_line)

    if delta >= Config.get(:nav_flash_threshold) and Config.get(:nav_flash) do
      FlashesWorkflow.replace_nav(state, current_line)
    else
      FlashesWorkflow.cancel_nav(state)
    end
  end
end
