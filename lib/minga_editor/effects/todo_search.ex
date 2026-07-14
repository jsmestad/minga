defmodule MingaEditor.Effects.TodoSearch do
  @moduledoc """
  Typed latest-wins TODO search owned by the TODO picker workflow.

  Repository probing and grep execution run in the generation-owned effect
  scheduler. The editor only applies the correlated picker result when its
  source, workspace root, and fetch revision are still live.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Project.Root
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Effects.TodoSearch.Port, as: TodoSearchPort
  alias MingaEditor.Effects.TodoSearch.Result
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.TodoSearchSource

  @keyword_pattern "(^|[[:space:]])(#|//|/\\*|%|--)[[:space:]]*(TODO|FIXME|HACK|NOTE|REVIEW|DEPRECATED)([^[:alnum:]_]|$)"

  @enforce_keys [:root, :revision]
  defstruct [:root, :revision, impl: TodoSearchPort]

  @type impl :: module()
  @type t :: %__MODULE__{root: Root.t(), revision: reference(), impl: impl()}

  @doc "Builds a latest-wins TODO search request for one project root."
  @spec request(Root.t(), reference()) :: Request.t()
  def request(%Root{} = root, revision) when is_reference(revision) do
    Request.new(
      %__MODULE__{root: root, revision: revision, impl: impl()},
      {:todo_search, root},
      Policy.latest_wins()
    )
  end

  @impl true
  @spec run(t()) :: {:ok, Result.t()} | {:error, String.t()}
  def run(%__MODULE__{root: root} = effect) do
    case Root.inventory_path(root) do
      {:ok, canonical_root} -> run_authorized(effect, canonical_root)
      {:error, reason} -> {:error, authorization_failure(reason)}
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
        } = outcome
      ) do
    apply_matching_revision(state, effect, result, outcome, result.revision == effect.revision)
  end

  def apply(
        state,
        %Outcome{status: :failed, request: %Request{effect: effect}, reason: reason} = outcome
      ) do
    apply_failed_for_workspace(
      state,
      effect,
      failure_message(reason),
      outcome,
      active_workspace_root()
    )
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec run_authorized(t(), String.t()) :: {:ok, Result.t()} | {:error, String.t()}
  defp run_authorized(%__MODULE__{revision: revision, impl: impl}, canonical_root) do
    with {:ok, output} <- search_output(canonical_root, impl) do
      items =
        output
        |> TodoSearchSource.parse_output()
        |> TodoSearchSource.build_candidates(canonical_root)

      {:ok,
       %Result{
         revision: revision,
         items: items,
         candidates: Candidate.from_items(items),
         meta: %{}
       }}
    end
  end

  @spec apply_matching_revision(EditorState.t(), t(), Result.t(), Outcome.t(), boolean()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_matching_revision(state, effect, result, outcome, true) do
    apply_completed_for_workspace(state, effect, result, outcome, active_workspace_root())
  end

  defp apply_matching_revision(state, _effect, _result, outcome, false) do
    {state, Outcome.stale(outcome, :revision_mismatch)}
  end

  @spec apply_completed_for_workspace(
          EditorState.t(),
          t(),
          Result.t(),
          Outcome.t(),
          Root.t() | nil
        ) :: {EditorState.t(), Outcome.t()}
  defp apply_completed_for_workspace(
         state,
         %__MODULE__{root: root} = effect,
         result,
         outcome,
         root
       ) do
    apply_completed_result(state, effect, result, outcome)
  end

  defp apply_completed_for_workspace(state, _effect, _result, outcome, _active_root) do
    {state, Outcome.stale(outcome, :workspace_rerooted)}
  end

  @spec apply_failed_for_workspace(
          EditorState.t(),
          t(),
          String.t(),
          Outcome.t(),
          Root.t() | nil
        ) :: {EditorState.t(), Outcome.t()}
  defp apply_failed_for_workspace(state, %__MODULE__{root: root} = effect, reason, outcome, root) do
    apply_failed_result(state, effect, reason, outcome)
  end

  defp apply_failed_for_workspace(state, _effect, _reason, outcome, _active_root) do
    {state, Outcome.stale(outcome, :workspace_rerooted)}
  end

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

  @spec active_workspace_root() :: Root.t() | nil
  defp active_workspace_root do
    Minga.Project.workspace_root()
  catch
    :exit, _reason -> nil
  end

  @spec impl() :: impl()
  defp impl do
    Application.get_env(:minga, :todo_search_port_module, TodoSearchPort)
  end

  @spec search_output(String.t(), impl()) :: {:ok, String.t()} | {:error, String.t()}
  defp search_output(canonical_root, port_backend) do
    if git_repo?(canonical_root, port_backend) do
      run_search_command(
        port_backend,
        "git",
        ["-C", canonical_root, "grep", "-n", "-I", "-E", @keyword_pattern, "--", "."]
      )
    else
      run_search_command(port_backend, "grep", [
        "-rnEI",
        "--exclude-dir=.git",
        @keyword_pattern,
        canonical_root
      ])
    end
  end

  @spec git_repo?(String.t(), impl()) :: boolean()
  defp git_repo?(canonical_root, port_backend) do
    case port_backend.run("git", ["-C", canonical_root, "rev-parse", "--is-inside-work-tree"]) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  @spec run_search_command(impl(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp run_search_command(port_backend, command, args) do
    case port_backend.run(command, args) do
      {output, 0} -> {:ok, output}
      {_output, 1} -> {:ok, ""}
      {output, status} -> {:error, "#{command} exited with status #{status}: #{output}"}
    end
  end

  @spec authorization_failure(Root.error()) :: String.t()
  defp authorization_failure(reason), do: "TODO search root rejected: #{reason}"

  @spec failure_message(term()) :: String.t()
  defp failure_message({:worker_exit, reason}),
    do: "TODO search worker failed: #{inspect(reason)}"

  defp failure_message({:start_failed, reason}),
    do: "TODO search worker failed: #{inspect(reason)}"

  defp failure_message(reason) when is_binary(reason), do: reason
  defp failure_message(reason), do: "TODO search failed: #{inspect(reason)}"
end
