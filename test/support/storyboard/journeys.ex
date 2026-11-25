defmodule Minga.Test.Storyboard.Journeys do
  @moduledoc """
  The main journeys from `docs/design/storyboard.md`, as scripted flows over scenario ids.

  A journey starts in a scenario and takes designed exits one at a time. Each step names the exit by its `key` field in `docs/design/scenarios.toml`, so a journey cannot take a path the inventory does not have: `validate/1` checks every step against the exit table. When the exit's key is written in words (`↩ on a done row`), the step gives the keys to press with `press:`.

  `run/2` drives the real editor along the journey, classifying the frame after every step, and stops at the first scenario whose surface is still pending. It returns the frames it saw, so #4036 can render the same journey as a strip of frames.
  """

  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Inventory
  alias Minga.Test.Storyboard.Keys
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Session

  @typedoc "One step: take the exit `key` from the current scenario to `to`."
  @type step :: %{key: String.t(), to: String.t(), press: String.t() | nil}

  @typedoc "A scripted journey."
  @type t :: %{name: String.t(), start: String.t(), steps: [step()]}

  @typedoc "One frame of a journey run: where the step landed and the semantic model."
  @type frame :: %{scenario: String.t(), keys: String.t(), model: Model.t()}

  @typedoc "The outcome of a run."
  @type outcome ::
          {:ok, [frame()]}
          | {:pending, String.t(), pos_integer(), [frame()]}
          | {:error, String.t(), [frame()]}

  @doc "The main journeys, in the order `storyboard.md` lists them."
  @spec all() :: [t()]
  def all do
    [
      journey("approve a request", "edit.working", [
        {"SPC a a", "minga.tasks.needs_you"},
        {"=", "minga.approval.diff"},
        {"y", "minga.tasks.working"},
        {"q", "edit.plain"}
      ]),
      journey("review and keep a change", "edit.working", [
        {"SPC a r", "minga.review.buffer"},
        {"y", "minga.review.buffer"},
        {"Y", "minga.review.keep_all.confirm"},
        {"y", "minga.review.all_decided"},
        {"q", "edit.plain"}
      ]),
      journey("recover from a rate limit", "minga.tasks.list", [
        {"r", "minga.tasks.working"},
        {"q", "edit.plain"}
      ]),
      journey("a failing test, then Minga fixes it, then review", "edit.working", [
        {"SPC o t", "terminal.drawer"},
        {"↩ on a failed block (Normal)", "terminal.failed_block.menu", press: "↩"},
        {"f", "minga.conversation"},
        {"SPC a r", "minga.review.buffer"},
        {"q", "edit.working"}
      ]),
      journey("open a file across a multi-file change", "edit.working", [
        {"SPC a r", "minga.review.buffer"},
        {"↩", "minga.review.in_file"},
        {"]h", "minga.review.in_file"},
        {"SPC a y", "edit.working"}
      ]),
      journey("peek into a subagent and step through its siblings", "edit.working", [
        {"SPC a v", "minga.conversation"},
        {"↩ on a Started line", "minga.subagent.peek", press: "↩"},
        {"]] / [[", "minga.subagent.peek", press: "]]"},
        {"q", "minga.conversation"}
      ])
    ]
  end

  @doc """
  Checks every step against the inventory's exit table.

  Returns the list of problems: a step whose exit does not exist, or whose keys are not a key path and give no `press:`.
  """
  @spec validate(t()) :: [String.t()]
  def validate(%{name: name, start: start, steps: steps}) do
    {problems, _at} =
      Enum.reduce(steps, {[], start}, fn step, {problems, from} ->
        {problems ++ step_problems(name, from, step), step.to}
      end)

    problems
  end

  @doc "The scenario ids a journey visits, starting scenario first."
  @spec scenario_ids(t()) :: [String.t()]
  def scenario_ids(%{start: start, steps: steps}), do: [start | Enum.map(steps, & &1.to)]

  @doc """
  Drives the real editor along the journey and classifies each frame.

  Stops with `{:pending, scenario, issue, frames}` at the first scenario whose surface waits on a ticket, and with `{:error, message, frames}` when a frame classifies as the wrong scenario. `opts` go to `Minga.Test.Storyboard.Session.start/1`.
  """
  @spec run(t(), keyword()) :: outcome()
  def run(%{start: start, steps: steps} = journey, opts \\ []) do
    case pending_issue(start) do
      nil ->
        session = Registry.drive(start, opts)
        first = frame(start, "", session)
        follow(steps, session, [first], journey)

      issue ->
        {:pending, start, issue, []}
    end
  end

  @spec follow([step()], Session.t(), [frame()], t()) :: outcome()
  defp follow([], _session, frames, _journey), do: {:ok, Enum.reverse(frames)}

  defp follow([step | rest], session, frames, journey) do
    case pending_issue(step.to) do
      nil -> take(step, rest, session, frames, journey)
      issue -> {:pending, step.to, issue, Enum.reverse(frames)}
    end
  end

  @spec take(step(), [step()], Session.t(), [frame()], t()) :: outcome()
  defp take(step, rest, session, frames, journey) do
    keys = step.press || step.key
    session = Session.press(session, keys)
    frame = frame(step.to, keys, session)

    case Registry.classify(frame.model) do
      to when to == step.to ->
        follow(rest, session, [frame | frames], journey)

      other ->
        {:error,
         "#{journey.name}: #{keys} landed on #{inspect(other)}, expected #{step.to} (#{Model.signature(frame.model)})",
         Enum.reverse([frame | frames])}
    end
  end

  @spec frame(String.t(), String.t(), Session.t()) :: frame()
  defp frame(scenario, keys, session),
    do: %{scenario: scenario, keys: keys, model: Session.model(session)}

  @spec pending_issue(String.t()) :: pos_integer() | nil
  defp pending_issue(id) do
    case Registry.fetch!(id) do
      %Entry{status: {:pending, issue, _reason}} -> issue
      %Entry{} -> nil
    end
  end

  @spec step_problems(String.t(), String.t(), step()) :: [String.t()]
  defp step_problems(name, from, %{key: key, to: to, press: press}) do
    exits = from |> Inventory.fetch!() |> Inventory.exits()

    cond do
      not Enum.any?(exits, &(&1["key"] == key and &1["to"] == to)) ->
        ["#{name}: #{from} has no exit #{inspect(key)} to #{to}"]

      press == nil and Keys.parse(key) == :not_a_key_path ->
        ["#{name}: #{from} exit #{inspect(key)} is not a key path; give press:"]

      true ->
        []
    end
  end

  @spec journey(String.t(), String.t(), [
          {String.t(), String.t()} | {String.t(), String.t(), keyword()}
        ]) :: t()
  defp journey(name, start, steps) do
    %{name: name, start: start, steps: Enum.map(steps, &step/1)}
  end

  @spec step({String.t(), String.t()} | {String.t(), String.t(), keyword()}) :: step()
  defp step({key, to}), do: %{key: key, to: to, press: nil}
  defp step({key, to, opts}), do: %{key: key, to: to, press: Keyword.get(opts, :press)}
end
