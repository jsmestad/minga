defmodule MingaEditor.Effects.TodoSearch do
  @moduledoc """
  Typed latest-wins TODO search owned by the TODO picker workflow.

  Repository probing and grep execution run in the generation-owned effect
  scheduler. The editor only applies the correlated picker result when its
  source and fetch revision are still live.
  """

  @behaviour MingaEditor.Effect

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.TodoSearchSource
  alias MingaEditor.PickerUI

  @keyword_pattern "(^|[[:space:]])(#|//|/\\*|%|--)[[:space:]]*(TODO|FIXME|HACK|NOTE|REVIEW|DEPRECATED)([^[:alnum:]_]|$)"
  @command_timeout_ms 5_000

  @enforce_keys [:root, :revision]
  defstruct [:root, :revision]

  @type t :: %__MODULE__{root: String.t(), revision: reference()}

  alias MingaEditor.Effects.TodoSearch.Result

  @doc "Builds a latest-wins TODO search request for one project root."
  @spec request(String.t(), reference()) :: Request.t()
  def request(root, revision) when is_binary(root) and is_reference(revision) do
    Request.new(
      %__MODULE__{root: root, revision: revision},
      {:todo_search, root},
      Policy.latest_wins()
    )
  end

  @impl true
  @spec run(t()) :: {:ok, Result.t()} | {:error, String.t()}
  def run(%__MODULE__{root: root, revision: revision}) do
    with {:ok, output} <- search_output(root) do
      items =
        output
        |> TodoSearchSource.parse_output()
        |> TodoSearchSource.build_candidates(root)

      {:ok,
       %Result{
         root: root,
         revision: revision,
         items: items,
         candidates: Candidate.from_items(items),
         meta: %{}
       }}
    end
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{}, %__MODULE__{} = newer), do: newer

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{
          status: :completed,
          request: %Request{effect: effect},
          result: %Result{} = result
        } =
          outcome
      ) do
    if result.revision == effect.revision do
      apply_completed_result(state, effect, result, outcome)
    else
      {state, Outcome.stale(outcome, :revision_mismatch)}
    end
  end

  def apply(
        state,
        %Outcome{status: :failed, request: %Request{effect: effect}, reason: reason} = outcome
      ) do
    apply_failed_result(state, effect, failure_message(reason), outcome)
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec apply_completed_result(EditorState.t(), t(), Result.t(), Outcome.t()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_completed_result(state, effect, result, outcome) do
    case PickerUI.apply_fetch_result(
           state,
           TodoSearchSource,
           effect.revision,
           {:ok, result.items, result.candidates, result.meta}
         ) do
      {:ok, state} -> {state, outcome}
      :stale -> {state, Outcome.stale(outcome, :picker_closed_or_replaced)}
    end
  end

  @spec apply_failed_result(EditorState.t(), t(), String.t(), Outcome.t()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_failed_result(state, effect, reason, outcome) do
    case PickerUI.apply_fetch_result(state, TodoSearchSource, effect.revision, {:error, reason}) do
      {:ok, state} -> {state, outcome}
      :stale -> {state, Outcome.stale(outcome, :picker_closed_or_replaced)}
    end
  end

  defp search_output(root) do
    if git_repo?(root) do
      run_search_command("git", [
        "-C",
        root,
        "grep",
        "-n",
        "-I",
        "-E",
        @keyword_pattern,
        "--",
        "."
      ])
    else
      run_search_command("grep", ["-rnEI", "--exclude-dir=.git", @keyword_pattern, root])
    end
  end

  defp git_repo?(root) do
    case run_port("git", ["-C", root, "rev-parse", "--is-inside-work-tree"]) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp run_search_command(command, args) do
    case run_port(command, args) do
      {output, 0} -> {:ok, output}
      {_output, 1} -> {:ok, ""}
      {output, status} -> {:error, "#{command} exited with status #{status}: #{output}"}
    end
  end

  defp run_port(command, args) do
    case System.find_executable(command) do
      nil -> {"#{command} executable not found", 127}
      executable -> open_port(executable, args)
    end
  rescue
    error -> {Exception.message(error), 1}
  end

  defp open_port(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:args, args},
        {:line, 65_536}
      ])

    collect_port_output(port, [])
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, {:eol, chunk}}} -> collect_port_output(port, ["\n", chunk | acc])
      {^port, {:data, {:noeol, chunk}}} -> collect_port_output(port, [chunk | acc])
      {^port, {:exit_status, status}} -> {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      @command_timeout_ms ->
        Port.close(port)
        {"command timed out", 124}
    end
  end

  defp failure_message({:worker_exit, reason}),
    do: "TODO search worker failed: #{inspect(reason)}"

  defp failure_message({:start_failed, reason}),
    do: "TODO search worker failed: #{inspect(reason)}"

  defp failure_message(reason) when is_binary(reason), do: reason
  defp failure_message(reason), do: "TODO search failed: #{inspect(reason)}"
end
