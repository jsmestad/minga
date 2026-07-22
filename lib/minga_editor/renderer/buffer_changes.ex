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
  alias MingaEditor.Renderer.ResidentWindowState
  alias MingaEditor.Renderer.State

  @doc "Reconciles lifecycle, consumes changed buffers once, and materializes pipeline input."
  @spec prepare(State.t(), Intent.t()) :: {State.t(), Input.t()}

  def prepare(%State{} = state, %Intent{} = intent) do
    state = State.reconcile_windows(state, intent)
    state = consume_changed_buffers(state, intent.buffer_versions)
    {state, materialize(state, intent)}
  end

  @doc "Commits renderer-owned per-window cache state after a successful pipeline frame."
  @spec commit(State.t(), Input.t(), Intent.t()) :: State.t()
  def commit(%State{} = state, %Input{} = output, %Intent{}) do
    residents =
      Enum.reduce(output.workspace.windows.map, state.resident_windows, fn {id, window}, acc ->
        case Map.get(acc, id) do
          %ResidentWindowState{} = resident ->
            version = Map.get(state.buffer_versions, resident.buffer)
            Map.put(acc, id, ResidentWindowState.commit_window(resident, window, version))

          nil ->
            acc
        end
      end)

    %{state | resident_windows: residents}
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
  end

  @doc "Handles an exact monitored buffer death."
  @spec handle_down(State.t(), reference(), pid()) :: State.t()
  def handle_down(%State{} = state, ref, buffer) do
    {state, _matched?} = State.drop_buffer_down(state, ref, buffer)
    state
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
    prior_range = pending_affected_range(state.resident_windows, buffer)
    consumed = safe_consume(buffer, observed_version, prior_range)
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

    %{
      state
      | resident_windows: residents,
        buffer_versions: Map.put(state.buffer_versions, buffer, consumed.version)
    }
  end

  @spec safe_consume(
          pid(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()} | nil
        ) :: RendererConsume.t()
  defp safe_consume(buffer, fallback_version, prior_range) do
    Minga.Buffer.renderer_consume(buffer, prior_range)
  catch
    :exit, _ ->
      %RendererConsume{
        version: fallback_version,
        line_count: 1,
        change_sequence: 0,
        changes: :reset_required,
        snapshot: nil
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

        {id, updated}

      pair ->
        pair
    end)
  end

  @spec pending_affected_range(
          %{optional(MingaEditor.Window.id()) => ResidentWindowState.t()},
          pid()
        ) :: {non_neg_integer(), non_neg_integer()} | nil
  defp pending_affected_range(residents, buffer) do
    snapshots =
      Enum.flat_map(residents, fn
        {_id, %ResidentWindowState{buffer: ^buffer, render_cache: cache}} ->
          case MingaEditor.Renderer.WindowCache.changed_snapshot(cache) do
            %RenderSnapshot{} = snapshot -> [snapshot]
            nil -> []
          end

        _ ->
          []
      end)

    pending_range_from_snapshots(snapshots, residents, buffer)
  end

  @spec pending_range_from_snapshots(
          [RenderSnapshot.t()],
          %{optional(MingaEditor.Window.id()) => ResidentWindowState.t()},
          pid()
        ) :: {non_neg_integer(), non_neg_integer()} | nil
  defp pending_range_from_snapshots([_ | _] = snapshots, _residents, _buffer) do
    Enum.reduce(snapshots, nil, fn snapshot, range ->
      last = snapshot.first_line + max(length(snapshot.lines) - 1, 0)
      union_range(range, {snapshot.first_line, last})
    end)
  end

  defp pending_range_from_snapshots([], residents, buffer) do
    deltas =
      Enum.find_value(residents, [], fn
        {_id, %ResidentWindowState{buffer: ^buffer, render_cache: cache}} ->
          case MingaEditor.Renderer.WindowCache.pending_edit_deltas(cache) do
            [] -> nil
            pending -> pending
          end

        _ ->
          nil
      end)

    EditDelta.affected_line_range(deltas)
  end

  @spec union_range(
          {non_neg_integer(), non_neg_integer()} | nil,
          {non_neg_integer(), non_neg_integer()}
        ) :: {non_neg_integer(), non_neg_integer()}
  defp union_range(nil, range), do: range

  defp union_range({first, last}, {new_first, new_last}),
    do: {min(first, new_first), max(last, new_last)}

  @spec materialize(State.t(), Intent.t()) :: Input.t()
  defp materialize(%State{} = state, %Intent{} = intent) do
    map =
      Map.new(intent.windows, fn {id, %WindowIntent{} = carrier} ->
        cache = materialize_cache(state, id)
        {id, WindowIntent.materialize(id, carrier, cache)}
      end)

    windows = struct!(Windows, Map.put(intent.window_layout, :map, map))
    workspace = intent.workspace |> Map.from_struct() |> Map.put(:windows, windows)
    message_store = merge_message_store(intent.frame.message_store, state.message_store)

    intent.frame
    |> Map.from_struct()
    |> Map.merge(%{
      workspace: workspace,
      caches: state.caches,
      font_registry: state.font_registry,
      message_store: message_store
    })
    |> then(&struct!(Input, &1))
  end

  @spec materialize_cache(State.t(), MingaEditor.Window.id()) ::
          MingaEditor.Renderer.WindowCache.t()
  defp materialize_cache(state, id) do
    case Map.get(state.resident_windows, id) do
      %ResidentWindowState{} = resident ->
        MingaEditor.Renderer.WindowCache.with_fetch_version(
          resident.render_cache,
          resident.last_version
        )

      nil ->
        MingaEditor.Renderer.WindowCache.reset()
    end
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
