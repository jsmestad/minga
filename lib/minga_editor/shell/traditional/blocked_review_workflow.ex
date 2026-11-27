defmodule MingaEditor.Shell.Traditional.BlockedReviewWorkflow do
  @moduledoc "Names a blocked user history step and resolves its revision-bound review offer."

  alias Minga.Buffer
  alias Minga.Buffer.UndoHistory
  alias Minga.RenderModel.UI.EmptyList.Action
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.InFileReview
  alias MingaEditor.Shell.Traditional.Notice
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.WhichKey

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

  @spec offered_for?(EditorState.t(), pid()) :: boolean()
  def offered_for?(state, buffer) do
    match?(%ShellState{blocked_review: {^buffer, _target}}, Runtime.state(state.shell_runtime))
  end

  @doc "Keeps the exact blocker only through the shortcut offered by its notice."
  @spec before_key(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  def before_key(
        %{shell_runtime: %{state: %ShellState{blocked_review: {buffer, _target}} = shell}} = state,
        key,
        mods
      ) do
    if state.workspace.buffers.active == buffer and offered_key?(shell, key, mods),
      do: state,
      else: put_offer(state, nil)
  end

  def before_key(state, _key, _mods), do: state

  @spec offered_key?(ShellState.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp offered_key?(%ShellState{notice: %Notice{actions: @actions}}, 32, 0), do: true
  defp offered_key?(%ShellState{whichkey: %WhichKey{prefix_keys: ["SPC"]}}, ?a, 0), do: true

  defp offered_key?(%ShellState{whichkey: %WhichKey{prefix_keys: ["SPC", "a"]}}, key, 0),
    do: key in [?y, ?d]

  defp offered_key?(_shell, _key, _mods), do: false

  @spec decide(EditorState.t(), pid(), :keep | :reject) :: EditorState.t()
  def decide(state, buffer, decision) do
    case Runtime.state(state.shell_runtime) do
      %ShellState{blocked_review: {^buffer, target}} ->
        state
        |> put_offer(nil)
        |> InFileReview.sequence(
          {:decide_blocking_change, buffer, target, decision},
          &decide_prepared/2
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

  @doc "Resolves the exact blocker captured when the user activated its action."
  @spec decide_prepared(
          EditorState.t(),
          {:decide_blocking_change, pid(), Buffer.Process.review_target(), :keep | :reject}
        ) :: EditorState.t()
  def decide_prepared(state, {:decide_blocking_change, buffer, target, decision}) do
    case decision do
      :keep ->
        InFileReview.keep_blocker(state, buffer, target)

      :reject ->
        NoticeWorkflow.publish(
          state,
          decision_message(Buffer.decide_review(buffer, target, :reject))
        )
    end
  catch
    :exit, _reason ->
      NoticeWorkflow.publish(state, "Nothing changed. The original buffer is unavailable.")
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
          {:ok, [UndoHistory.rejected_unit()]}
          | UndoHistory.blocked()
          | {:error, Buffer.Process.review_error()}
        ) :: String.t()
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
