defmodule MingaEditor.Renderer.BufferChanges do
  @moduledoc """
  Renderer-side buffer ChangeLog consumption and per-window fanout.

  Windows are grouped by buffer PID. A changed buffer/version advances the
  `:renderer` consumer cursor exactly once, then the ordered result is applied
  to every resident window showing that PID.
  """

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RenderSnapshot
  alias Minga.Buffer.RendererConsume
  alias Minga.Telemetry
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.State.Windows
  alias MingaEditor.Renderer.ObservedBuffers
  alias MingaEditor.Renderer.ResidentWindowState
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Renderer.State

  @doc "Reconciles lifecycle, consumes changed buffers once, and materializes pipeline input."
  @spec prepare(State.t(), Intent.t()) :: {State.t(), Input.t()}

  def prepare(%State{} = state, %Intent{} = intent) do
    state = State.reconcile_windows(state, intent)
    versions = ObservedBuffers.monitored_versions(state.observed_buffers, intent.buffer_versions)
    state = consume_changed_buffers(state, versions)
    {state, highlights} = State.prepare_highlights(state, intent)
    {state, materialize(state, intent, highlights)}
  end

  @doc "Installs per-window caches and retires incorporated deltas after frame acceptance."
  @spec commit(State.t(), Input.t(), Intent.t()) :: State.t()
  def commit(%State{} = state, %Input{} = output, %Intent{}) do
    residents =
      Enum.reduce(output.windows.map, state.resident_windows, fn {id, window}, acc ->
        case Map.get(acc, id) do
          %ResidentWindowState{} = resident ->
            version = ObservedBuffers.recorded_version(state.observed_buffers, resident.buffer)
            Map.put(acc, id, ResidentWindowState.commit_window(resident, window, version))

          nil ->
            acc
        end
      end)

    %{state | resident_windows: residents}
    |> State.commit_review_windows(output)
  end

  @doc "Invalidates one renderer-owned window for targeted frontend recovery."
  @spec invalidate_window(State.t(), MingaEditor.Window.id()) :: State.t()
  def invalidate_window(%State{} = state, window_id) do
    residents =
      Map.update(state.resident_windows, window_id, nil, fn resident ->
        ResidentWindowState.require_hydration(
          resident,
          :reset_required,
          resident.last_version || 0
        )
      end)
      |> Map.reject(fn {_id, value} -> is_nil(value) end)

    %{state | resident_windows: residents}
    |> State.invalidate_review_window(window_id)
  end

  @spec consume_changed_buffers(State.t(), %{optional(pid()) => non_neg_integer()}) :: State.t()
  defp consume_changed_buffers(state, versions) do
    Enum.reduce(versions, state, fn {buffer, version}, acc ->
      consume_buffer_if_changed(acc, buffer, version)
    end)
  end

  @spec consume_buffer_if_changed(State.t(), pid(), non_neg_integer()) :: State.t()
  defp consume_buffer_if_changed(%State{} = state, buffer, observed_version) do
    # This call is intentionally unconditional. Besides advancing changed buffers,
    # it closes the consume/fetch race when a retry reuses an older editor intent.
    prior_ranges = pending_affected_ranges(state.resident_windows, buffer)
    consumed = safe_consume(buffer, observed_version, prior_ranges)
    residents = fanout(state.resident_windows, buffer, consumed)

    delta_count =
      case consumed.changes do
        {:ok, deltas} -> length(deltas)
        :reset_required -> 0
      end

    Telemetry.execute(
      [:minga, :render, :buffer_deltas],
      %{deltas_consumed: delta_count, changelog_consumes: 1},
      %{
        buffer: buffer,
        version: consumed.version,
        reset_required?: consumed.changes == :reset_required
      }
    )

    observed_buffers =
      ObservedBuffers.record_version(state.observed_buffers, buffer, consumed.version)

    %{state | resident_windows: residents, observed_buffers: observed_buffers}
  end

  @spec safe_consume(pid(), non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]) ::
          RendererConsume.t()
  defp safe_consume(buffer, fallback_version, prior_ranges) do
    Minga.Buffer.renderer_consume(buffer, prior_ranges)
  catch
    :exit, _ ->
      %RendererConsume{
        version: fallback_version,
        line_count: 1,
        change_sequence: 0,
        changes: :reset_required,
        snapshot: nil,
        review_lease: nil,
        review_damage: :reset_required
      }
  end

  @spec fanout(
          %{optional(MingaEditor.Window.id()) => ResidentWindowState.t()},
          pid(),
          RendererConsume.t()
        ) :: %{optional(MingaEditor.Window.id()) => ResidentWindowState.t()}
  defp fanout(residents, buffer, %RendererConsume{} = consumed) do
    Map.new(residents, fn
      {id, %ResidentWindowState{buffer: ^buffer} = resident} ->
        updated =
          case consumed.changes do
            {:ok, deltas} ->
              ResidentWindowState.apply_deltas(
                resident,
                deltas,
                consumed.snapshot,
                consumed.version,
                consumed.line_count,
                consumed.change_sequence
              )

            :reset_required ->
              ResidentWindowState.require_hydration(
                resident,
                :reset_required,
                consumed.version,
                consumed.line_count,
                consumed.change_sequence
              )
          end

        {id, ResidentWindowState.observe_review(updated, consumed)}

      pair ->
        pair
    end)
  end

  # The line ranges still pending for a buffer, in its current coordinates. A window that holds a changed
  # snapshot already knows them exactly; otherwise they come from the deltas it has not rendered yet.
  @spec pending_affected_ranges(
          %{optional(MingaEditor.Window.id()) => ResidentWindowState.t()},
          pid()
        ) :: [{non_neg_integer(), non_neg_integer()}]
  defp pending_affected_ranges(residents, buffer) do
    caches =
      for {_id, %ResidentWindowState{buffer: ^buffer, render_cache: cache}} <- residents,
          do: cache

    snapshot_ranges =
      Enum.flat_map(caches, fn cache ->
        case MingaEditor.Renderer.WindowCache.changed_snapshot(cache) do
          %RenderSnapshot{} = snapshot -> RenderSnapshot.line_ranges(snapshot)
          nil -> []
        end
      end)

    case snapshot_ranges do
      [] ->
        caches
        |> Enum.find_value([], fn cache ->
          case MingaEditor.Renderer.WindowCache.pending_edit_deltas(cache) do
            [] -> nil
            pending -> pending
          end
        end)
        |> EditDelta.affected_line_ranges()

      ranges ->
        EditDelta.affected_line_ranges([], ranges)
    end
  end

  @spec materialize(State.t(), Intent.t(), MingaEditor.Renderer.HighlightCache.highlights()) ::
          Input.t()
  defp materialize(%State{} = state, %Intent{} = intent, highlights) do
    map =
      Map.new(intent.windows, fn {id, %WindowIntent{} = carrier} ->
        cache = State.window_cache(state, id)
        {id, RenderWindow.materialize(id, carrier, cache)}
      end)

    windows =
      Windows.new(
        intent.window_layout.tree,
        intent.window_layout.active,
        intent.window_layout.next_id,
        map
      )

    message_store = merge_message_store(intent.frame.message_store, state.message_store)

    Input.from_intent(
      intent,
      windows,
      state.caches,
      state.font_registry,
      message_store,
      highlights
    )
  end

  @spec merge_message_store(
          MingaEditor.UI.Panel.MessageStore.t(),
          MingaEditor.UI.Panel.MessageStore.t() | nil
        ) :: MingaEditor.UI.Panel.MessageStore.t()
  defp merge_message_store(current, nil), do: current

  defp merge_message_store(current, latest) do
    MingaEditor.UI.Panel.MessageStore.merge_sent_cursor(current, latest)
  end
end
