defmodule Minga.Test.Storyboard.Inventory do
  @moduledoc """
  The scenario inventory in `docs/design/scenarios.toml`, read as data, plus the design-time flow checks.

  `flow_problems/2` is the ExUnit port of `design/tools/storyboard/check.py`. It checks the inventory graph, not the running editor: unknown exit targets, reachability by key and by click from the cold start, dead ends, lists without an empty state, key and click parity on transient exits, and board files. The Python checker stays for design-time use; both read the same file, so they cannot disagree about what the inventory says.

  Scenarios are plain maps with string keys, exactly as TOML decodes them.
  """

  @path Path.expand("../../../docs/design/scenarios.toml", __DIR__)
  @boards_dir Path.expand("../../../design/boards", __DIR__)
  @external_resource @path

  @back_keys ["esc", "q"]

  @inventory (fn ->
                data = @path |> File.read!() |> Toml.decode!()
                %{phase: Map.get(data, "phase", "final"), scenarios: Map.fetch!(data, "scenario")}
              end).()

  @typedoc "One `[[scenario]]` table from the inventory."
  @type scenario :: %{optional(String.t()) => term()}

  @typedoc "One exit of a scenario: `key`, `click`, `to`, and optional `keyboard_only`, `back`, `note`."
  @type exit :: %{optional(String.t()) => term()}

  @typedoc "The decoded inventory."
  @type t :: %{phase: String.t(), scenarios: [scenario()]}

  @typedoc "Problem categories reported by `flow_problems/2`, the same as `check.py`."
  @type category ::
          :unknown_target
          | :unreachable_by_key
          | :unreachable_by_click
          | :dead_end
          | :no_empty_state
          | :parity
          | :no_click
          | :missing_board
          | :state_with_exits

  @categories [
    :unknown_target,
    :unreachable_by_key,
    :unreachable_by_click,
    :dead_end,
    :no_empty_state,
    :parity,
    :no_click,
    :missing_board,
    :state_with_exits
  ]

  @doc "Path of the inventory file."
  @spec path() :: Path.t()
  def path, do: @path

  @doc """
  The decoded inventory. The file is read when this module compiles (it is an external resource), so lookups never re-parse it.
  """
  @spec load() :: t()
  def load, do: @inventory

  @doc "Reads and decodes another inventory file. Raises when it does not parse."
  @spec load(Path.t()) :: t()
  def load(path) do
    data = path |> File.read!() |> Toml.decode!()
    %{phase: Map.get(data, "phase", "final"), scenarios: Map.fetch!(data, "scenario")}
  end

  @doc "Every scenario in the inventory, in file order."
  @spec scenarios() :: [scenario()]
  def scenarios, do: @inventory.scenarios

  @doc """
  Ids of every designed place, in file order: scenarios with `status = "designed"` that are not `state_of` another scenario.

  A `state_of` scenario (a narrow window) is a state the designed places can be in. It has no registry entry and no renders; the places it applies to prove it.
  """
  @spec designed_ids() :: [String.t()]
  def designed_ids do
    for %{"status" => "designed", "id" => id} = scenario <- scenarios(),
        not Map.get(scenario, "state_of", false),
        do: id
  end

  @doc "Looks up one scenario by id."
  @spec fetch(String.t()) :: {:ok, scenario()} | :error
  def fetch(id) do
    case Enum.find(scenarios(), &(&1["id"] == id)) do
      nil -> :error
      scenario -> {:ok, scenario}
    end
  end

  @doc "Like `fetch/1`, but raises for an unknown id."
  @spec fetch!(String.t()) :: scenario()
  def fetch!(id) do
    case fetch(id) do
      {:ok, scenario} -> scenario
      :error -> raise ArgumentError, "no scenario #{inspect(id)} in #{@path}"
    end
  end

  @doc "Ids of the resting views (`home = true`)."
  @spec home_ids() :: [String.t()]
  def home_ids do
    for %{"id" => id} = scenario <- scenarios(), scenario["home"] == true, do: id
  end

  @doc "The exits of a scenario."
  @spec exits(scenario()) :: [exit()]
  def exits(scenario), do: Map.get(scenario, "exits", [])

  @doc "True when an exit is an escape: `esc`, `q`, a sequence starting with either, or `back = true`."
  @spec back?(exit()) :: boolean()
  def back?(%{"back" => true}), do: true

  def back?(exit) do
    key = exit |> Map.get("key", "") |> String.trim()
    key in @back_keys or String.starts_with?(key, "esc ") or String.starts_with?(key, "q ")
  end

  @doc """
  Runs the design-time flow checks over the scenarios and returns every problem by category.

  Mirrors `check.py`: removed scenarios are skipped, a state of other scenarios (`state_of`) may not list exits of its own, states that are not places (no exits) are not checked for reachability or dead ends, and scenarios with `reached_by` count as reachable.
  """
  @spec flow_problems([scenario()], Path.t()) :: %{category() => [String.t()]}
  def flow_problems(scenarios, boards_dir \\ @boards_dir) do
    by_id = Map.new(scenarios, &{&1["id"], &1})
    live = Enum.reject(scenarios, &(&1["status"] == "removed"))

    %{
      unknown_target: unknown_targets(live, by_id),
      no_empty_state: missing_empty_states(live, by_id),
      dead_end: dead_ends(live, by_id),
      parity: transient_gaps(live, :click_without_key),
      no_click: transient_gaps(live, :key_without_click),
      missing_board: missing_boards(live, boards_dir),
      state_with_exits: for(s <- live, s["state_of"] == true, exits(s) != [], do: s["id"])
    }
    |> Map.merge(unreachable(live, by_id))
  end

  @doc "Problem categories in report order."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "Categories that are mouse gaps, pending while the inventory is in the keyboard phase."
  @spec mouse_categories() :: [category()]
  def mouse_categories, do: [:unreachable_by_click, :no_click]

  @spec unknown_targets([scenario()], map()) :: [String.t()]
  defp unknown_targets(live, by_id) do
    for scenario <- live, exit <- exits(scenario), not Map.has_key?(by_id, exit["to"]) do
      "#{scenario["id"]} -> #{exit["to"]}"
    end
  end

  @spec unreachable([scenario()], map()) :: %{
          unreachable_by_key: [String.t()],
          unreachable_by_click: [String.t()]
        }
  defp unreachable(live, by_id) do
    case for(%{"id" => id} = s <- live, s["cold_start"] == true, do: id) do
      [start] ->
        roots = [start | for(%{"id" => id} = s <- live, s["reached_by"], do: id)]
        by_key = reach(roots, edges(live, by_id, "key"))
        by_click = reach(roots, edges(live, by_id, "click"))
        places = Enum.filter(live, &(exits(&1) != [] or &1["terminal_state"] == true))

        %{
          unreachable_by_key: for(%{"id" => id} <- places, id not in by_key, do: id),
          unreachable_by_click: for(%{"id" => id} <- places, id not in by_click, do: id)
        }

      starts ->
        %{
          unreachable_by_key: [
            "expected exactly one cold_start scenario, found #{inspect(starts)}"
          ],
          unreachable_by_click: []
        }
    end
  end

  @spec edges([scenario()], map(), String.t()) :: %{String.t() => [String.t()]}
  defp edges(live, by_id, field) do
    Map.new(live, fn scenario ->
      targets =
        for exit <- exits(scenario),
            Map.has_key?(by_id, exit["to"]),
            String.trim(Map.get(exit, field, "")) != "",
            do: exit["to"]

      # A list reaches its empty state the same way it is reached itself.
      empty =
        if Map.has_key?(by_id, scenario["empty_state"]), do: [scenario["empty_state"]], else: []

      {scenario["id"], targets ++ empty}
    end)
  end

  @spec reach([String.t()], %{String.t() => [String.t()]}) :: MapSet.t(String.t())
  defp reach(roots, edges), do: do_reach(roots, MapSet.new(roots), edges)

  defp do_reach([], seen, _edges), do: seen

  defp do_reach([current | rest], seen, edges) do
    next = edges |> Map.get(current, []) |> Enum.reject(&MapSet.member?(seen, &1))
    do_reach(rest ++ next, Enum.into(next, seen), edges)
  end

  @spec dead_ends([scenario()], map()) :: [String.t()]
  defp dead_ends(live, by_id) do
    homes = for %{"id" => id} = s <- live, s["home"] == true, into: MapSet.new(), do: id

    back_edges =
      Map.new(live, fn scenario ->
        {scenario["id"],
         for(
           exit <- exits(scenario),
           back?(exit),
           Map.has_key?(by_id, exit["to"]),
           do: exit["to"]
         )}
      end)

    for scenario <- live,
        not MapSet.member?(homes, scenario["id"]),
        scenario["terminal_state"] != true,
        scenario["outside_app"] != true,
        exits(scenario) != [],
        not home_within?(MapSet.new([scenario["id"]]), back_edges, homes, 3),
        do: scenario["id"]
  end

  @spec home_within?(MapSet.t(), map(), MapSet.t(), non_neg_integer()) :: boolean()
  defp home_within?(_frontier, _back_edges, _homes, 0), do: false

  defp home_within?(frontier, back_edges, homes, steps) do
    next =
      for id <- frontier, target <- Map.get(back_edges, id, []), into: MapSet.new(), do: target

    if MapSet.disjoint?(next, homes),
      do: home_within?(next, back_edges, homes, steps - 1),
      else: true
  end

  @spec missing_empty_states([scenario()], map()) :: [String.t()]
  defp missing_empty_states(live, by_id) do
    for %{"list" => true} = scenario <- live, problem = empty_state_problem(scenario, by_id) do
      problem
    end
  end

  @spec empty_state_problem(scenario(), map()) :: String.t() | nil
  defp empty_state_problem(%{"id" => id} = scenario, by_id) do
    case scenario["empty_state"] do
      nil -> "#{id} (no empty_state)"
      target when is_map_key(by_id, target) -> nil
      target -> "#{id} -> #{target} (unknown)"
    end
  end

  @spec transient_gaps([scenario()], :click_without_key | :key_without_click) :: [String.t()]
  defp transient_gaps(live, gap) do
    for %{"transient" => true} = scenario <- live,
        exit <- exits(scenario),
        not Map.has_key?(exit, "keyboard_only"),
        message = transient_gap(scenario["id"], exit, gap),
        do: message
  end

  @spec transient_gap(String.t(), exit(), :click_without_key | :key_without_click) ::
          String.t() | nil
  defp transient_gap(id, exit, gap) do
    key = exit |> Map.get("key", "") |> String.trim()
    click = exit |> Map.get("click", "") |> String.trim()

    case {gap, key, click} do
      {:key_without_click, key, ""} when key != "" -> "#{id}: '#{key}' has no click"
      {:click_without_key, "", click} when click != "" -> "#{id}: '#{click}' has no key"
      _ -> nil
    end
  end

  @spec missing_boards([scenario()], Path.t()) :: [String.t()]
  defp missing_boards(live, boards_dir) do
    for scenario <- live,
        name <- board_files(scenario),
        not File.regular?(Path.join(boards_dir, name)),
        do: "#{scenario["id"]}: #{name}"
  end

  @spec board_files(scenario()) :: [String.t()]
  defp board_files(scenario) do
    scenario
    |> Map.get("boards", %{})
    |> Map.values()
    |> Enum.flat_map(&List.wrap/1)
  end
end
