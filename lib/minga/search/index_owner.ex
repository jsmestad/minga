defmodule Minga.Search.IndexOwner do
  @moduledoc "Owns the sole current persistent GUI search index per buffer and serves exact-generation bounded queries."

  use GenServer

  alias Minga.Buffer.EditDelta
  alias Minga.Editing.Search.Index
  alias Minga.Editing.Search.Match
  alias Minga.Search.IndexGeneration

  @type entry :: {IndexGeneration.t(), Index.t()}
  @type state :: %{
          entries: %{optional(pid()) => entry()},
          monitors: %{optional(pid()) => reference()}
        }
  @type summary :: %{match_count: non_neg_integer(), current_index: non_neg_integer()}
  @type stats :: %{count: non_neg_integer(), metrics: Index.metrics()}

  @doc "Starts the source-owned search index service."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    start_link_with_name(Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Installs a fully built index as the sole current generation."
  @spec install(
          GenServer.server(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Index.t()
        ) ::
          {:ok, IndexGeneration.t()}
  def install(server \\ __MODULE__, buffer, query_revision, version, sequence, %Index{} = index) do
    GenServer.call(server, {:install, buffer, query_revision, version, sequence, index})
  end

  @doc "Applies exact incremental edits and advances the current document generation."
  @spec apply_edits(
          GenServer.server(),
          IndexGeneration.t(),
          non_neg_integer(),
          non_neg_integer(),
          [EditDelta.t()],
          non_neg_integer(),
          [String.t()]
        ) ::
          {:ok, IndexGeneration.t()} | :stale
  def apply_edits(
        server \\ __MODULE__,
        %IndexGeneration{} = generation,
        version,
        sequence,
        deltas,
        first_line,
        lines
      ) do
    GenServer.call(
      server,
      {:apply_edits, generation, version, sequence, deltas, first_line, lines}
    )
  end

  @doc "Returns count and cursor ordinal for the exact current generation."
  @spec summary(GenServer.server(), IndexGeneration.t(), Minga.Editing.Search.position()) ::
          {:ok, summary()} | :stale
  def summary(server \\ __MODULE__, %IndexGeneration{} = generation, cursor) do
    GenServer.call(server, {:summary, generation, cursor})
  end

  @doc "Returns matches whose line lies in the inclusive range for the exact current generation."
  @spec matches_in_range(
          GenServer.server(),
          IndexGeneration.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, [Match.t()]} | :stale
  def matches_in_range(
        server \\ __MODULE__,
        %IndexGeneration{} = generation,
        first_line,
        last_line
      ) do
    GenServer.call(server, {:matches_in_range, generation, first_line, last_line})
  end

  @doc "Returns the next match for the exact current generation."
  @spec next(
          GenServer.server(),
          IndexGeneration.t(),
          Minga.Editing.Search.position(),
          Minga.Editing.Search.direction()
        ) ::
          {:ok, Match.t() | nil} | :stale
  def next(server \\ __MODULE__, %IndexGeneration{} = generation, cursor, direction) do
    GenServer.call(server, {:next, generation, cursor, direction})
  end

  @doc "Returns the exact cursor match for the exact current generation."
  @spec match_at(GenServer.server(), IndexGeneration.t(), Minga.Editing.Search.position()) ::
          {:ok, Match.t() | nil} | :stale
  def match_at(server \\ __MODULE__, %IndexGeneration{} = generation, cursor) do
    GenServer.call(server, {:match_at, generation, cursor})
  end

  @doc "Checks whether the generation is still the sole current generation."
  @spec current?(GenServer.server(), IndexGeneration.t()) :: boolean()
  def current?(server \\ __MODULE__, %IndexGeneration{} = generation) do
    GenServer.call(server, {:current?, generation})
  end

  @doc "Returns count and matching-work metrics for the exact current generation."
  @spec stats(GenServer.server(), IndexGeneration.t()) :: {:ok, stats()} | :stale
  def stats(server \\ __MODULE__, %IndexGeneration{} = generation) do
    GenServer.call(server, {:stats, generation})
  end

  @impl true
  @spec init(:ok) :: {:ok, state()}
  def init(:ok), do: {:ok, %{entries: %{}, monitors: %{}}}

  @impl true
  def handle_call({:install, buffer, query_revision, version, sequence, index}, _from, state) do
    generation = IndexGeneration.new(buffer, query_revision, version, sequence)
    {:reply, {:ok, generation}, put_entry(state, generation, index)}
  end

  def handle_call(
        {:apply_edits, generation, version, sequence, deltas, first_line, lines},
        _from,
        state
      ) do
    case fetch_index(state, generation) do
      {:ok, index} ->
        updated = Index.apply_edits(index, deltas, first_line, lines)

        next =
          IndexGeneration.new(
            generation.buffer,
            generation.query_revision,
            version,
            sequence
          )

        {:reply, {:ok, next}, put_entry(state, next, updated)}

      :stale ->
        {:reply, :stale, state}
    end
  end

  def handle_call({:summary, generation, cursor}, _from, state) do
    reply =
      with {:ok, index} <- fetch_index(state, generation) do
        {:ok,
         %{match_count: Index.count(index), current_index: Index.current_ordinal(index, cursor)}}
      end

    {:reply, reply, state}
  end

  def handle_call({:matches_in_range, generation, first, last}, _from, state) do
    reply =
      with {:ok, index} <- fetch_index(state, generation) do
        {:ok, Index.matches_in_range(index, first, last)}
      end

    {:reply, reply, state}
  end

  def handle_call({:next, generation, cursor, direction}, _from, state) do
    reply =
      with {:ok, index} <- fetch_index(state, generation) do
        {:ok, Index.next(index, cursor, direction)}
      end

    {:reply, reply, state}
  end

  def handle_call({:match_at, generation, cursor}, _from, state) do
    reply =
      with {:ok, index} <- fetch_index(state, generation) do
        {:ok, Index.match_at(index, cursor)}
      end

    {:reply, reply, state}
  end

  def handle_call({:current?, generation}, _from, state),
    do: {:reply, match?({:ok, _index}, fetch_index(state, generation)), state}

  def handle_call({:stats, generation}, _from, state) do
    reply =
      with {:ok, index} <- fetch_index(state, generation) do
        {:ok, %{count: Index.count(index), metrics: Index.metrics(index)}}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, buffer, _reason}, state) do
    case Map.get(state.monitors, buffer) do
      ^ref ->
        {:noreply,
         %{
           state
           | entries: Map.delete(state.entries, buffer),
             monitors: Map.delete(state.monitors, buffer)
         }}

      _other ->
        {:noreply, state}
    end
  end

  @spec fetch_index(state(), IndexGeneration.t()) :: {:ok, Index.t()} | :stale
  defp fetch_index(%{entries: entries}, %IndexGeneration{buffer: buffer} = generation) do
    case Map.get(entries, buffer) do
      {^generation, index} -> {:ok, index}
      _other -> :stale
    end
  end

  @spec put_entry(state(), IndexGeneration.t(), Index.t()) :: state()
  defp put_entry(state, generation, index) do
    state = ensure_monitor(state, generation.buffer)
    %{state | entries: Map.put(state.entries, generation.buffer, {generation, index})}
  end

  @spec ensure_monitor(state(), pid()) :: state()
  defp ensure_monitor(%{monitors: monitors} = state, buffer) do
    if Map.has_key?(monitors, buffer) do
      state
    else
      %{state | monitors: Map.put(monitors, buffer, Process.monitor(buffer))}
    end
  end

  @spec start_link_with_name(GenServer.name() | nil) :: GenServer.on_start()
  defp start_link_with_name(nil), do: GenServer.start_link(__MODULE__, :ok)
  defp start_link_with_name(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
end
