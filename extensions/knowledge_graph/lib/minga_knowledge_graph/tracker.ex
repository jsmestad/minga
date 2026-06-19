defmodule MingaKnowledgeGraph.Tracker do
  @moduledoc """
  Builds and persists the per-user familiarity graph.

  Subscribes to buffer open/change/save events, accumulates per-file
  activity (open and edit counts, recency), and pushes a 0..4 heat level
  per path to `Minga.Extension.Badge` so the file tree tints by
  familiarity. When you open a file you are unfamiliar with, it kicks off a
  streaming briefing into a float panel.

  State persists across sessions via `Minga.Extension.Storage`; on first
  run it seeds from recent git history so the tree is not all-cold.
  """

  use GenServer

  alias Minga.Buffer
  alias Minga.Events.BufferChangedEvent
  alias Minga.Events.BufferEvent
  alias Minga.Extension.AI
  alias Minga.Extension.Badge
  alias Minga.Extension.Storage
  alias MingaKnowledgeGraph.Briefing
  alias MingaKnowledgeGraph.Score

  @extension_name :minga_knowledge_graph
  @storage_file "graph.json"
  @persist_debounce_ms 5_000
  # A prior familiarity below this triggers a briefing on open (level < 2).
  @briefing_threshold 0.30
  @briefing_max_tokens 700
  @seed_since "6 months ago"

  @type stats :: Score.stats()
  @type state :: %{
          graph: %{String.t() => stats()},
          levels: %{String.t() => 0..4},
          briefed: MapSet.t(String.t()),
          briefings: %{reference() => {String.t(), String.t()}},
          persist_timer: reference() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns a short familiarity summary string for `path`."
  @spec familiarity(GenServer.server(), String.t()) :: String.t()
  def familiarity(server \\ __MODULE__, path) do
    GenServer.call(server, {:familiarity, path})
  end

  @doc "Requests a briefing for `path` (always generated, even if familiar)."
  @spec request_briefing(GenServer.server(), String.t()) :: :ok
  def request_briefing(server \\ __MODULE__, path) do
    GenServer.cast(server, {:request_briefing, path})
  end

  @doc "Re-pushes every tracked file's heat level to the badge registry."
  @spec refresh_heat(GenServer.server()) :: :ok
  def refresh_heat(server \\ __MODULE__) do
    GenServer.cast(server, :refresh_heat)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    Process.flag(:trap_exit, true)
    subscribe()

    now = now()
    graph = if Keyword.get(opts, :seed, true), do: load_or_seed(now), else: load_graph()

    state =
      %{
        graph: graph,
        levels: %{},
        briefed: MapSet.new(),
        briefings: %{},
        persist_timer: nil
      }
      |> refresh_all_levels(now)

    {:ok, state}
  end

  @impl true
  def handle_call({:familiarity, path}, _from, state) do
    {:reply, familiarity_summary(state, normalize(path)), state}
  end

  @impl true
  def handle_cast({:request_briefing, path}, state) do
    {:noreply, start_briefing(state, normalize(path))}
  end

  def handle_cast(:refresh_heat, state) do
    {:noreply, refresh_all_levels(%{state | levels: %{}}, now())}
  end

  @impl true
  def handle_info({:minga_event, :buffer_opened, %BufferEvent{path: path}}, state)
      when is_binary(path) do
    {:noreply, on_open(state, normalize(path))}
  end

  def handle_info(
        {:minga_event, :buffer_changed, %BufferChangedEvent{source: :user, buffer: buffer}},
        state
      ) do
    case safe_file_path(buffer) do
      nil -> {:noreply, state}
      path -> {:noreply, on_activity(state, normalize(path), :edit)}
    end
  end

  def handle_info({:minga_event, :buffer_saved, %BufferEvent{path: path}}, state)
      when is_binary(path) do
    {:noreply, on_activity(state, normalize(path), :touch)}
  end

  def handle_info({:minga_ai, ref, event}, state) do
    {:noreply, handle_ai_event(state, ref, event)}
  end

  def handle_info(:persist, state) do
    save_graph(state.graph)
    {:noreply, %{state | persist_timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    save_graph(state.graph)
    :ok
  end

  # ── Activity tracking ─────────────────────────────────────────────────────

  @spec on_open(state(), String.t()) :: state()
  defp on_open(state, path) do
    now = now()
    prior = Map.get(state.graph, path)
    prior_score = if prior, do: Score.score(prior, now), else: 0.0

    state = on_activity(state, path, :open, now)

    if prior_score < @briefing_threshold and not MapSet.member?(state.briefed, path) do
      start_briefing(state, path)
    else
      state
    end
  end

  @spec on_activity(state(), String.t(), :open | :edit | :touch, integer() | nil) :: state()
  defp on_activity(state, path, kind, now \\ nil) do
    now = now || now()
    updated = bump(Map.get(state.graph, path), now, kind)

    %{state | graph: Map.put(state.graph, path, updated)}
    |> push_level(path, updated, now)
    |> schedule_persist()
  end

  @spec bump(stats() | nil, integer(), :open | :edit | :touch) :: stats()
  defp bump(nil, now, kind) do
    bump(%{first_seen: now, last_seen: now, open_count: 0, edit_count: 0}, now, kind)
  end

  defp bump(stats, now, :open), do: %{stats | last_seen: now, open_count: stats.open_count + 1}
  defp bump(stats, now, :edit), do: %{stats | last_seen: now, edit_count: stats.edit_count + 1}
  defp bump(stats, now, :touch), do: %{stats | last_seen: now}

  # ── Heat levels ───────────────────────────────────────────────────────────

  # Only writes to the badge registry when the level actually changes, so a
  # burst of edits doesn't re-render the file tree on every keystroke.
  @spec push_level(state(), String.t(), stats(), integer()) :: state()
  defp push_level(state, path, stats, now) do
    level = Score.level(Score.score(stats, now))

    if Map.get(state.levels, path) == level do
      state
    else
      Badge.set_file(@extension_name, path, level: level)
      %{state | levels: Map.put(state.levels, path, level)}
    end
  end

  @spec refresh_all_levels(state(), integer()) :: state()
  defp refresh_all_levels(state, now) do
    Enum.reduce(state.graph, state, fn {path, stats}, acc ->
      push_level(acc, path, stats, now)
    end)
  end

  # ── Briefings ─────────────────────────────────────────────────────────────

  @spec start_briefing(state(), String.t()) :: state()
  defp start_briefing(state, path) do
    case File.read(path) do
      {:ok, content} ->
        Briefing.render(path, {:generating})

        {:ok, ref} =
          AI.stream(Briefing.messages(path, content),
            reply_to: self(),
            max_tokens: @briefing_max_tokens
          )

        %{
          state
          | briefed: MapSet.put(state.briefed, path),
            briefings: Map.put(state.briefings, ref, {path, ""})
        }

      {:error, _reason} ->
        state
    end
  end

  @spec handle_ai_event(state(), reference(), AI.event()) :: state()
  defp handle_ai_event(state, ref, event) do
    case Map.get(state.briefings, ref) do
      nil ->
        state

      {path, acc} ->
        apply_ai_event(state, ref, path, acc, event)
    end
  end

  @spec apply_ai_event(state(), reference(), String.t(), String.t(), AI.event()) :: state()
  defp apply_ai_event(state, ref, path, acc, {:chunk, text}) do
    acc = acc <> text
    Briefing.render(path, {:text, acc})
    %{state | briefings: Map.put(state.briefings, ref, {path, acc})}
  end

  defp apply_ai_event(state, ref, path, _acc, {:done, full}) do
    Briefing.render(path, {:text, full})
    %{state | briefings: Map.delete(state.briefings, ref)}
  end

  defp apply_ai_event(state, ref, path, _acc, {:error, reason}) do
    Briefing.render(path, {:error, reason})
    %{state | briefings: Map.delete(state.briefings, ref)}
  end

  # ── Familiarity summary ───────────────────────────────────────────────────

  @spec familiarity_summary(state(), String.t()) :: String.t()
  defp familiarity_summary(state, path) do
    case Map.get(state.graph, path) do
      nil ->
        "#{Path.basename(path)}: unfamiliar (never opened)"

      stats ->
        level = Score.level(Score.score(stats, now()))

        "#{Path.basename(path)}: #{label(level)} (opened #{stats.open_count}×, edited #{stats.edit_count}×)"
    end
  end

  @spec label(0..4) :: String.t()
  defp label(0), do: "unfamiliar"
  defp label(1), do: "barely seen"
  defp label(2), do: "some familiarity"
  defp label(3), do: "familiar"
  defp label(4), do: "well-known"

  # ── Persistence ───────────────────────────────────────────────────────────

  @spec load_or_seed(integer()) :: %{String.t() => stats()}
  defp load_or_seed(now) do
    case load_graph() do
      graph when map_size(graph) > 0 -> graph
      _empty -> seed_from_git(now)
    end
  end

  @spec load_graph() :: %{String.t() => stats()}
  defp load_graph do
    with {:ok, bin} <- Storage.read(@extension_name, @storage_file),
         {:ok, raw} when is_map(raw) <- JSON.decode(bin) do
      decode_graph(raw)
    else
      _ -> %{}
    end
  end

  @spec save_graph(%{String.t() => stats()}) :: :ok
  defp save_graph(graph) do
    case Storage.write(@extension_name, @storage_file, JSON.encode!(graph)) do
      :ok -> :ok
      _ -> :ok
    end
  end

  @spec decode_graph(map()) :: %{String.t() => stats()}
  defp decode_graph(raw) do
    Map.new(raw, fn {path, s} ->
      {path,
       %{
         first_seen: int(s["first_seen"]),
         last_seen: int(s["last_seen"]),
         open_count: int(s["open_count"]),
         edit_count: int(s["edit_count"])
       }}
    end)
  end

  @spec schedule_persist(state()) :: state()
  defp schedule_persist(state) do
    if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
    ref = Process.send_after(self(), :persist, @persist_debounce_ms)
    %{state | persist_timer: ref}
  end

  # ── Git cold-start seed ───────────────────────────────────────────────────

  # ponytail: bounded to the last 6 months of history so the seed is cheap on
  # large repos. Files committed recently/often start warm; everything else cold.
  @spec seed_from_git(integer()) :: %{String.t() => stats()}
  defp seed_from_git(_now) do
    case git_log() do
      {:ok, output} -> build_seed(output)
      :error -> %{}
    end
  end

  @spec git_log() :: {:ok, String.t()} | :error
  defp git_log do
    case System.cmd(
           "git",
           ["log", "--since=#{@seed_since}", "--name-only", "--pretty=format:%H %ct", "--", "."],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @spec build_seed(String.t()) :: %{String.t() => stats()}
  defp build_seed(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, &seed_line/2)
    |> elem(0)
  end

  @spec seed_line(String.t(), {map(), integer() | nil}) :: {map(), integer() | nil}
  defp seed_line("", acc), do: acc

  defp seed_line(line, {graph, commit_time}) do
    case Regex.run(~r/^[0-9a-f]{7,40} (\d+)$/, line) do
      [_, ct] -> {graph, String.to_integer(ct)}
      nil -> {seed_file(graph, line, commit_time), commit_time}
    end
  end

  @spec seed_file(map(), String.t(), integer() | nil) :: map()
  defp seed_file(graph, _rel_path, nil), do: graph

  defp seed_file(graph, rel_path, ct) do
    path = Path.expand(rel_path)

    Map.update(
      graph,
      path,
      %{first_seen: ct, last_seen: ct, open_count: 0, edit_count: 1},
      fn s ->
        %{
          s
          | first_seen: min(s.first_seen, ct),
            last_seen: max(s.last_seen, ct),
            edit_count: s.edit_count + 1
        }
      end
    )
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  @spec subscribe() :: :ok
  defp subscribe do
    Minga.Events.subscribe(:buffer_opened)
    Minga.Events.subscribe(:buffer_changed)
    Minga.Events.subscribe(:buffer_saved)
    :ok
  end

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(buffer) do
    Buffer.file_path(buffer)
  catch
    :exit, _ -> nil
  end

  @spec normalize(String.t()) :: String.t()
  defp normalize(path), do: Path.expand(path)

  @spec now() :: integer()
  defp now, do: System.os_time(:second)

  @spec int(term()) :: integer()
  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)
  defp int(_), do: 0
end
