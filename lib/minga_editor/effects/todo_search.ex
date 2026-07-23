defmodule MingaEditor.Effects.TodoSearch do
  @moduledoc """
  Typed latest-wins TODO search owned by the TODO picker workflow.

  Repository probing and grep execution run in the generation-owned effect
  scheduler. The editor only applies the correlated picker result when its
  source, workspace activation, and fetch revision are still live.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Project.Root
  alias Minga.Project.WorkspaceSnapshot
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
  @truncated_status "Results truncated to #{TodoSearchSource.max_results()}"

  @enforce_keys [:root, :activation_id, :revision]
  defstruct [:root, :activation_id, :revision, impl: TodoSearchPort]

  @type impl :: module()
  @type t :: %__MODULE__{
          root: Root.t(),
          activation_id: WorkspaceSnapshot.activation_id(),
          revision: reference(),
          impl: impl()
        }
  @type output_format :: TodoSearchSource.output_format()

  @doc "Builds a latest-wins TODO search request for one captured workspace activation."
  @spec request(WorkspaceSnapshot.t(), reference()) :: Request.t()
  def request(
        %WorkspaceSnapshot{root: %Root{} = root, activation_id: activation_id},
        revision
      )
      when is_reference(revision) do
    Request.new(
      %__MODULE__{root: root, activation_id: activation_id, revision: revision, impl: impl()},
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
          value: {:completed, %Result{} = result},
          request: %Request{effect: effect}
        } = outcome
      ) do
    apply_matching_revision(state, effect, result, outcome, result.revision == effect.revision)
  end

  def apply(
        state,
        %Outcome{value: {:failed, reason}, request: %Request{effect: effect}} = outcome
      ) do
    apply_failed_for_workspace(
      state,
      effect,
      failure_message(reason),
      outcome,
      active_workspace_snapshot()
    )
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec run_authorized(t(), String.t()) :: {:ok, Result.t()} | {:error, String.t()}
  defp run_authorized(%__MODULE__{root: root, revision: revision, impl: impl}, canonical_root) do
    with {:ok, output, format} <- search_output(canonical_root, impl) do
      {markers, truncated?} = TodoSearchSource.parse_output(output, format)
      items = TodoSearchSource.build_candidates(markers, root)

      {:ok,
       %Result{
         revision: revision,
         items: items,
         candidates: Candidate.from_items(items),
         meta: result_meta(truncated?)
       }}
    end
  end

  @spec apply_matching_revision(EditorState.t(), t(), Result.t(), Outcome.t(), boolean()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_matching_revision(state, effect, result, outcome, true) do
    apply_completed_for_workspace(state, effect, result, outcome, active_workspace_snapshot())
  end

  defp apply_matching_revision(state, _effect, _result, outcome, false) do
    {state, Outcome.stale(outcome, :revision_mismatch)}
  end

  @spec apply_completed_for_workspace(
          EditorState.t(),
          t(),
          Result.t(),
          Outcome.t(),
          WorkspaceSnapshot.t() | nil
        ) :: {EditorState.t(), Outcome.t()}
  defp apply_completed_for_workspace(
         state,
         %__MODULE__{root: root, activation_id: activation_id} = effect,
         result,
         outcome,
         %WorkspaceSnapshot{root: root, activation_id: activation_id}
       ) do
    apply_completed_result(state, effect, result, outcome)
  end

  defp apply_completed_for_workspace(state, _effect, _result, outcome, _active_workspace) do
    {state, Outcome.stale(outcome, :workspace_rerooted)}
  end

  @spec apply_failed_for_workspace(
          EditorState.t(),
          t(),
          String.t(),
          Outcome.t(),
          WorkspaceSnapshot.t() | nil
        ) :: {EditorState.t(), Outcome.t()}
  defp apply_failed_for_workspace(
         state,
         %__MODULE__{root: root, activation_id: activation_id} = effect,
         reason,
         outcome,
         %WorkspaceSnapshot{root: root, activation_id: activation_id}
       ) do
    apply_failed_result(state, effect, reason, outcome)
  end

  defp apply_failed_for_workspace(state, _effect, _reason, outcome, _active_workspace) do
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

  @spec active_workspace_snapshot() :: WorkspaceSnapshot.t() | nil
  defp active_workspace_snapshot do
    Minga.Project.snapshot()
  catch
    :exit, _reason -> nil
  end

  @spec impl() :: impl()
  defp impl do
    Application.get_env(:minga, :todo_search_port_module, TodoSearchPort)
  end

  @spec result_meta(boolean()) :: MingaEditor.UI.Picker.Source.fetch_meta()
  defp result_meta(true), do: %{status: @truncated_status}
  defp result_meta(false), do: %{}

  @spec search_output(String.t(), impl()) ::
          {:ok, String.t(), output_format()} | {:error, String.t()}
  defp search_output(canonical_root, port_backend) do
    if git_repo?(canonical_root, port_backend) do
      run_search_command(
        port_backend,
        "git",
        ["-C", canonical_root, "grep", "-n", "-I", "-E", "-z", @keyword_pattern, "--", "."],
        :git
      )
    else
      run_search_command(
        port_backend,
        "grep",
        ["-rnEI", "--null", "--exclude-dir=.git", @keyword_pattern, canonical_root],
        :grep
      )
    end
  end

  @spec git_repo?(String.t(), impl()) :: boolean()
  defp git_repo?(canonical_root, port_backend) do
    case port_backend.run("git", ["-C", canonical_root, "rev-parse", "--is-inside-work-tree"]) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  @spec run_search_command(impl(), String.t(), [String.t()], output_format()) ::
          {:ok, String.t(), output_format()} | {:error, String.t()}
  defp run_search_command(port_backend, command, args, format) do
    case port_backend.run(command, args) do
      {output, 0} -> {:ok, output, format}
      {_output, 1} -> {:ok, "", format}
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
