defmodule MingaEditor.UI.Prompt.RejectTask do
  @moduledoc "Confirms rejection of the exact pending task and buffer offered by the editor."

  @behaviour MingaEditor.UI.Prompt.Handler

  alias Minga.Buffer
  alias Minga.Buffer.Author
  alias Minga.Buffer.UndoHistory
  alias MingaEditor.PromptUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @spec open(EditorState.t(), pid()) :: EditorState.t()
  def open(state, buffer) do
    case Buffer.prepare_review(buffer, :latest) do
      :empty ->
        NoticeWorkflow.publish(state, "No Minga changes to reject in this buffer")

      {:ok, target, task, count} ->
        PromptUI.open(state, __MODULE__,
          kind: :confirm,
          label: label(task, count),
          context: %{buffer: buffer, target: target}
        )
    end
  catch
    :exit, _reason -> unavailable(state)
  end

  @impl true
  @spec label() :: String.t()
  def label, do: "Reject all changes? Your edits stay."

  @impl true
  @spec on_submit(String.t(), EditorState.t()) :: EditorState.t()
  def on_submit(_text, state), do: unavailable(state)

  @impl true
  @spec on_submit(String.t(), EditorState.t(), map() | nil) :: EditorState.t()
  def on_submit(_text, state, %{buffer: buffer, target: target}) do
    case Buffer.decide_review(buffer, target, :reject) do
      {:ok, receipts} ->
        NoticeWorkflow.publish(state, "Rejected #{changes(length(receipts))}")

      {:blocked, {:overlaps, :you}} ->
        NoticeWorkflow.publish(state, "Nothing rejected. Your edit overlaps this task.")

      {:blocked, {:overlaps, key}} ->
        NoticeWorkflow.publish(
          state,
          "Nothing rejected. #{blocker_label(key)} overlaps this task."
        )

      {:error, :stale_review} ->
        NoticeWorkflow.publish(
          state,
          "Nothing rejected. The changes moved. Open Reject all again."
        )

      {:error, reason} ->
        NoticeWorkflow.publish(state, "Nothing rejected: #{inspect(reason)}")
    end
  catch
    :exit, _reason -> unavailable(state)
  end

  def on_submit(text, state, _context), do: on_submit(text, state)

  @spec unavailable(EditorState.t()) :: EditorState.t()
  defp unavailable(state),
    do: NoticeWorkflow.publish(state, "Nothing rejected. The original buffer is unavailable.")

  @spec label(UndoHistory.task(), pos_integer()) :: String.t()
  defp label(task, count),
    do: "Reject #{changes(count)} from #{task_label(task)}? Your edits stay."

  @spec changes(pos_integer()) :: String.t()
  defp changes(1), do: "1 change"
  defp changes(count), do: "#{count} changes"

  @spec task_label(UndoHistory.task()) :: String.t()
  defp task_label({:minga, :untasked}), do: "Minga (no task)"

  defp task_label({:minga, task}), do: "task #{short_id(task)}"

  @spec blocker_label(UndoHistory.minga_group()) :: String.t()
  defp blocker_label({:untasked, step}), do: "Minga change #{step}"

  defp blocker_label(key), do: "Minga #{task_label(Author.author(key))}"

  @spec short_id(String.t()) :: String.t()
  defp short_id(id) do
    case String.split_at(id, 14) do
      {prefix, ""} -> prefix
      {prefix, _rest} -> prefix <> "…"
    end
  end
end
