defmodule MingaEditor.Renderer.TextPresentations do
  @moduledoc "Owns committed, active, and explicitly discarded text-presentation leases."

  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Window

  defstruct leases: %{}, active: %{}

  @type key :: {Window.id(), pos_integer()}
  @type t :: %__MODULE__{
          leases: %{optional(key()) => TextPresentation.t()},
          active: %{optional(Window.id()) => pos_integer()}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Retains every presentation carried by one acknowledged pipeline output."
  @spec acknowledge_output(t(), Input.t()) :: t()
  def acknowledge_output(%__MODULE__{} = state, %Input{} = output) do
    presentations =
      Enum.flat_map(output.windows.map, fn
        {_window_id,
         %RenderWindow{render_cache: %{text_presentation: %TextPresentation{} = lease}}} ->
          [lease]

        {_window_id, _window} ->
          []
      end)

    acknowledge(state, presentations)
  end

  @doc "Retains acknowledged presentation candidates without changing visibility."
  @spec acknowledge(t(), [TextPresentation.t()]) :: t()
  def acknowledge(%__MODULE__{} = state, presentations) when is_list(presentations) do
    leases = Enum.reduce(presentations, state.leases, &Map.put(&2, key(&1), &1))
    %{state | leases: leases}
  end

  @doc "Marks an acknowledged presentation active only when its exact lease exists."
  @spec activate(t(), Window.id(), non_neg_integer()) :: {:ok, t()} | {:error, :unknown}
  def activate(%__MODULE__{} = state, window_id, presentation_id) do
    if Map.has_key?(state.leases, {window_id, presentation_id}) do
      {:ok, %{state | active: Map.put(state.active, window_id, presentation_id)}}
    else
      {:error, :unknown}
    end
  end

  @doc "Drops only the exact candidate named by the frontend lifecycle event."
  @spec discard(t(), Window.id(), non_neg_integer()) :: t()
  def discard(%__MODULE__{} = state, window_id, presentation_id) do
    active =
      case Map.get(state.active, window_id) do
        ^presentation_id -> Map.delete(state.active, window_id)
        _other -> state.active
      end

    %{state | leases: Map.delete(state.leases, {window_id, presentation_id}), active: active}
  end

  @doc "Resolves input only against the presentation currently declared visible."
  @spec resolve(t(), TextEvent.t()) ::
          {:ok, TextTarget.t()} | {:error, :inactive | atom()}
  def resolve(%__MODULE__{} = state, %TextEvent{} = event) do
    presentation_id = event.presentation_id

    with ^presentation_id <- Map.get(state.active, event.window_id),
         %TextPresentation{} = lease <-
           Map.get(state.leases, {event.window_id, event.presentation_id}) do
      TextPresentation.resolve(lease, event.row_index, event.row_id, event.utf16_offset)
    else
      _ -> {:error, :inactive}
    end
  end

  @spec drop_buffer(t(), pid()) :: t()
  def drop_buffer(%__MODULE__{} = state, buffer) when is_pid(buffer) do
    leases = Map.reject(state.leases, fn {_key, lease} -> lease.buffer == buffer end)

    active =
      Map.reject(state.active, fn {window_id, id} -> not Map.has_key?(leases, {window_id, id}) end)

    %{state | leases: leases, active: active}
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{}), do: new()

  @spec key(TextPresentation.t()) :: key()
  defp key(%TextPresentation{window_id: window_id, presentation_id: id}), do: {window_id, id}
end
