defmodule MingaEditor.Renderer.ResidentWindowState do
  @moduledoc """
  Renderer-owned durable state for one editor window/buffer pairing.

  The value is keyed by stable window id and is replaced when that window points
  at another buffer. It owns the complete render cache, durable line identity,
  resident build/store, row-slot allocator, and the authoritative pending
  buffer-delta queue held by `WindowCache`.
  """

  alias Minga.Buffer.EditDelta
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Window
  alias MingaEditor.Renderer.WindowCache, as: RenderCache

  @enforce_keys [:window_id, :buffer, :render_cache]
  defstruct [
    :window_id,
    :buffer,
    :render_cache,
    :last_version,
    :line_count,
    :change_sequence,
    hydration: :initial
  ]

  @type hydration_reason ::
          :initial
          | :reset_required
          | :buffer_replacement
          | :renderer_restart
          | :identity_reset
          | nil

  @type t :: %__MODULE__{
          window_id: Window.id(),
          buffer: pid(),
          render_cache: RenderCache.t(),
          last_version: non_neg_integer() | nil,
          line_count: pos_integer() | nil,
          change_sequence: non_neg_integer() | nil,
          hydration: hydration_reason()
        }

  @doc "Starts state for a newly observed window/buffer pair."
  @spec new(Window.id(), pid(), hydration_reason()) :: t()
  def new(window_id, buffer, reason \\ :initial)
      when is_integer(window_id) and is_pid(buffer) do
    %__MODULE__{
      window_id: window_id,
      buffer: buffer,
      render_cache: RenderCache.require_hydration(RenderCache.reset(), reason),
      last_version: nil,
      hydration: reason
    }
  end

  @doc "Copies the renderer-owned cache from a successful pipeline window."
  @spec commit_window(t(), RenderWindow.t(), non_neg_integer() | nil) :: t()
  def commit_window(%__MODULE__{} = state, %RenderWindow{} = window, _observed_version) do
    %{state | render_cache: window.render_cache, hydration: nil}
  end

  @doc "Applies newly consumed deltas exactly once and retains them until a frame commits."
  @spec apply_deltas(t(), [EditDelta.t()], non_neg_integer(), pos_integer(), non_neg_integer()) ::
          t()
  def apply_deltas(%__MODULE__{} = state, deltas, version, line_count, change_sequence)
      when is_list(deltas) do
    cache = RenderCache.apply_edit_deltas(state.render_cache, state.buffer, deltas)
    dirty = dirty_lines(deltas)

    %{
      state
      | render_cache: RenderCache.mark_dirty(cache, dirty),
        last_version: version,
        line_count: line_count,
        change_sequence: change_sequence,
        hydration: state.hydration
    }
  end

  @doc "Requests one explicit full hydration in a fresh content epoch."
  @spec require_hydration(
          t(),
          hydration_reason(),
          non_neg_integer(),
          pos_integer() | nil,
          non_neg_integer() | nil
        ) :: t()
  def require_hydration(state, reason, version, line_count \\ nil, sequence \\ nil)

  def require_hydration(%__MODULE__{} = state, nil, _version, _line_count, _sequence), do: state

  def require_hydration(%__MODULE__{} = state, reason, version, line_count, sequence) do
    %{
      state
      | render_cache: RenderCache.require_hydration(state.render_cache, reason),
        last_version: version,
        line_count: line_count,
        change_sequence: sequence,
        hydration: reason
    }
  end

  @spec dirty_lines([EditDelta.t()]) :: [non_neg_integer()]
  defp dirty_lines(deltas) do
    deltas
    |> Enum.flat_map(fn %EditDelta{start_position: {start_line, _}, new_end_position: {last, _}} ->
      Enum.to_list(start_line..max(start_line, last))
    end)
    |> Enum.uniq()
  end
end
