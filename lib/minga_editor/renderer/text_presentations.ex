defmodule MingaEditor.Renderer.TextPresentations do
  @moduledoc "Owns committed, active, and explicitly discarded text-presentation leases."

  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Renderer.TextInteractionIndex
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Window

  @enforce_keys [:index]
  defstruct [:index, leases: %{}]

  @type key :: {Window.id(), pos_integer()}
  @type t :: %__MODULE__{
          leases: %{optional(key()) => TextPresentation.t()},
          index: TextInteractionIndex.t()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{index: TextInteractionIndex.new()}

  @spec reader(t()) :: Reader.t()
  def reader(%__MODULE__{index: index}), do: TextInteractionIndex.reader(index)

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

    state = acknowledge(state, presentations)
    window_ids = MapSet.new(presentations, & &1.window_id)
    %{state | index: TextInteractionIndex.retain_current_windows(state.index, window_ids)}
  end

  @doc "Retains acknowledged presentation candidates without changing visibility."
  @spec acknowledge(t(), [TextPresentation.t()]) :: t()
  def acknowledge(%__MODULE__{} = state, presentations) when is_list(presentations) do
    Enum.reduce(presentations, state, fn presentation, acc ->
      presentation_key = key(presentation)

      if Map.has_key?(acc.leases, presentation_key) do
        acc
      else
        %{
          acc
          | leases: Map.put(acc.leases, presentation_key, presentation),
            index: TextInteractionIndex.publish(acc.index, presentation)
        }
      end
    end)
  end

  @doc "Marks an acknowledged presentation active only when its exact lease exists."
  @spec activate(t(), Window.id(), non_neg_integer()) :: {:ok, t()} | {:error, :unknown}
  def activate(%__MODULE__{} = state, window_id, presentation_id) do
    case TextInteractionIndex.activate(state.index, window_id, presentation_id) do
      :ok -> {:ok, state}
      {:error, :unknown} -> {:error, :unknown}
    end
  end

  @doc "Drops only the exact candidate named by the frontend lifecycle event."
  @spec discard(t(), Window.id(), non_neg_integer()) :: t()
  def discard(%__MODULE__{} = state, window_id, presentation_id) do
    case Map.pop(state.leases, {window_id, presentation_id}) do
      {nil, _leases} ->
        state

      {presentation, leases} ->
        %{
          state
          | leases: leases,
            index: TextInteractionIndex.discard(state.index, presentation)
        }
    end
  end

  @doc "Resolves input only against the presentation currently declared visible."
  @spec resolve(t(), TextEvent.t()) ::
          {:ok, TextTarget.t()} | {:error, :inactive | atom()}
  def resolve(%__MODULE__{} = state, %TextEvent{} = event) do
    state.index |> TextInteractionIndex.reader() |> Reader.resolve(event)
  end

  @spec drop_buffer(t(), pid()) :: t()
  def drop_buffer(%__MODULE__{} = state, buffer) when is_pid(buffer) do
    state =
      state.leases
      |> Map.values()
      |> Enum.filter(&(&1.buffer == buffer))
      |> Enum.reduce(state, fn presentation, acc ->
        discard(acc, presentation.window_id, presentation.presentation_id)
      end)

    %{state | index: TextInteractionIndex.drop_buffer(state.index, buffer)}
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = state) do
    %{state | leases: %{}, index: TextInteractionIndex.reset(state.index)}
  end

  @doc false
  @spec last_publication_nodes(t()) :: non_neg_integer()
  def last_publication_nodes(%__MODULE__{index: index}),
    do: TextInteractionIndex.last_publication_nodes(index)

  @spec key(TextPresentation.t()) :: key()
  defp key(%TextPresentation{window_id: window_id, presentation_id: id}), do: {window_id, id}
end
