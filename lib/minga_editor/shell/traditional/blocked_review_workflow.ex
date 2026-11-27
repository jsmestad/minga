defmodule MingaEditor.Shell.Traditional.BlockedReviewWorkflow do
  @moduledoc "Names a blocked user history step and resolves its revision-bound review offer."

  alias Minga.Buffer
  alias Minga.Buffer.UndoHistory
  alias Minga.RenderModel.UI.EmptyList.Action
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState

  @actions [
    %Action{id: "reject_blocking_change", key: "SPC a d", label: "Reject"},
    %Action{id: "keep_blocking_change", key: "SPC a y", label: "Keep"}
  ]

  @spec move_history(EditorState.t(), pid(), :undo | :redo) :: EditorState.t()
  def move_history(state, buffer, operation) do
    case Buffer.move_history(buffer, operation) do
      {:blocked, {:overlaps, key}, nil} ->
        state
        |> put_offer(nil)
        |> NoticeWorkflow.publish(blocked_message(operation, key))

      {:blocked, {:overlaps, key}, target} ->
        state
        |> put_offer({buffer, target})
        |> NoticeWorkflow.publish(blocked_message(operation, key), @actions)

      :ok ->
        put_offer(state, nil)

      {:error, reason} ->
        state
        |> put_offer(nil)
        |> NoticeWorkflow.publish("#{verb(operation)} refused: #{inspect(reason)}")
    end
  end

  @spec decide(EditorState.t(), pid(), :keep | :reject) :: EditorState.t()
  def decide(state, buffer, decision) do
    case Runtime.state(state.shell_runtime) do
      %ShellState{blocked_review: {^buffer, target}} ->
        state = put_offer(state, nil)

        NoticeWorkflow.publish(
          state,
          decision_message(Buffer.decide_review(buffer, target, decision))
        )

      %ShellState{} ->
        NoticeWorkflow.publish(state, "No blocked Minga change in this buffer. Try undo again.")
    end
  catch
    :exit, _reason ->
      state
      |> put_offer(nil)
      |> NoticeWorkflow.publish("Nothing changed. The original buffer is unavailable.")
  end

  @spec put_offer(EditorState.t(), ShellState.blocked_review() | nil) :: EditorState.t()
  defp put_offer(%{shell_runtime: %{state: %ShellState{blocked_review: offer}}} = state, offer),
    do: state

  defp put_offer(state, offer) do
    shell_state = state.shell_runtime |> Runtime.state() |> ShellState.put_blocked_review(offer)
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end

  @spec blocked_message(:undo | :redo, UndoHistory.minga_group() | :you) :: String.t()
  defp blocked_message(operation, key), do: "#{verb(operation)} blocked: #{change_name(key)}"

  @spec change_name(UndoHistory.minga_group() | :you) :: String.t()
  defp change_name({:minga, task, step}), do: "Minga #{short_id(task)}/#{short_id(step)}"
  defp change_name({:untasked, step}), do: "Minga change #{step}"
  defp change_name(:you), do: "your edit"

  @spec decision_message(
          :ok
          | {:ok, [UndoHistory.rejected_unit()]}
          | UndoHistory.blocked()
          | {:error, Buffer.Process.review_error()}
        ) :: String.t()
  defp decision_message(:ok), do: "Kept the blocking Minga change"
  defp decision_message({:ok, _receipts}), do: "Rejected the blocking Minga change"

  defp decision_message({:blocked, {:overlaps, key}}),
    do: "Nothing rejected. Overlaps #{change_name(key)}."

  defp decision_message({:error, :stale_review}),
    do: "Nothing changed. Try undo again to review the current blocker."

  defp decision_message({:error, reason}), do: "Nothing changed: #{inspect(reason)}"

  @spec verb(:undo | :redo) :: String.t()
  defp verb(:undo), do: "Undo"
  defp verb(:redo), do: "Redo"

  @spec short_id(String.t()) :: String.t()
  defp short_id(id) do
    case String.split_at(id, -4) do
      {"", suffix} -> suffix
      {_prefix, suffix} -> "…" <> suffix
    end
  end
end
