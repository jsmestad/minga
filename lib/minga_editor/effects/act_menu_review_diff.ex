defmodule MingaEditor.Effects.ActMenuReviewDiff do
  @moduledoc "Builds the read-only diff for the whole review offer outside the editor mailbox."
  @behaviour MingaEditor.Effect

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Effect.{Outcome, Policy, Request}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.HoverPopup
  alias MingaEditor.Session.State, as: SessionState

  alias MingaEditor.Shell.Traditional.{
    ActMenu,
    ActMenuWorkflow,
    HoverPopupWorkflow,
    NoticeWorkflow
  }

  alias MingaEditor.State
  alias MingaEditor.Window

  @enforce_keys [:file, :target]
  defstruct @enforce_keys

  @type t :: %__MODULE__{file: ActMenu.file_source(), target: BufferProcess.review_target()}

  @doc "Admits a preview for the same captured window and history, not the current caret."
  @spec open(State.t(), ActMenu.file_source(), BufferProcess.review_target()) :: State.t()
  def open(%State{effect_scheduler: nil} = state, _file, _target),
    do: NoticeWorkflow.publish(state, "Diff preview is unavailable")

  def open(%State{} = state, {window, _, _, _} = file, target) do
    request =
      Request.new(
        %__MODULE__{file: file, target: target},
        {:act_menu_diff, window},
        Policy.latest_wins()
      )

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _status} -> state
      {:error, _reason} -> NoticeWorkflow.publish(state, "Could not open the diff preview")
    end
  end

  @impl true
  @spec run(t()) :: {:ok, String.t()} | {:error, term()}
  def run(%__MODULE__{file: {_, buffer, _, _}, target: target}) do
    case Buffer.preview_review(buffer, target) do
      {:ok, before, proposed} ->
        path = Buffer.file_path(buffer) || "Minga change"
        {:ok, render_diff(DiffReview.new(path, before, proposed))}

      refusal ->
        {:error, refusal}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  @spec apply(State.t(), Outcome.t()) :: {State.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{request: %Request{effect: %__MODULE__{} = effect}, value: value} = outcome
      ) do
    case live_source(state, effect) do
      {:ok, row} -> {show(state, row, value), outcome}
      :stale -> {state, Outcome.stale(outcome, :review_source_changed)}
    end
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec render_diff(DiffReview.t() | nil) :: String.t()
  defp render_diff(nil), do: "No visible text differences."

  defp render_diff(%DiffReview{hunks: hunks, after_lines: lines}) do
    rows =
      hunks
      |> Stream.flat_map(fn hunk ->
        old = Stream.map(hunk.old_lines, &("- " <> &1))

        new =
          lines
          |> Stream.drop(hunk.start_line)
          |> Stream.take(hunk.count)
          |> Stream.map(&("+ " <> &1))

        Stream.concat([["@@ #{hunk.start_line + 1}"], old, new])
      end)
      |> Enum.take(73)

    {visible, remaining} = Enum.split(rows, 72)
    ending = if remaining == [], do: "```", else: "… more diff lines\n```"
    IO.iodata_to_binary(["```diff\n", Enum.map(visible, &[&1, "\n"]), ending])
  end

  @spec live_source(State.t(), t()) :: {:ok, non_neg_integer()} | :stale
  defp live_source(state, %__MODULE__{file: {id, buffer, version, {line, _}}, target: target}) do
    with nil <- ActMenuWorkflow.current(state),
         %Window{id: ^id, content: {:buffer, ^buffer}, viewport: viewport} <-
           SessionState.active_window_struct(state.workspace),
         :ok <- Buffer.review_offer_current(buffer, version, target) do
      {:ok, max(0, min(viewport.rows - 1, line - viewport.top))}
    else
      _gone -> :stale
    end
  catch
    :exit, _gone -> :stale
  end

  @spec show(State.t(), non_neg_integer(), Outcome.value()) :: State.t()
  defp show(state, row, {:completed, text}) do
    popup =
      text |> HoverPopup.Builder.new(row, 1, theme: state.appearance.theme) |> HoverPopup.focus()

    HoverPopupWorkflow.show(state, popup)
  end

  defp show(state, _row, {:failed, _reason}),
    do: NoticeWorkflow.publish(state, "Could not preview the exact reviewed change")

  defp show(state, _row, _canceled), do: state
end
