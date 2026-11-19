defmodule MingaEditor.UI.Picker.SelectionAttachmentTargetSource do
  @moduledoc "Chooses the exact local Agent draft that receives an explicitly captured selection."

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.Agent.{DraftSave, DraftWorkflow, SelectionAttachment, UIState}
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent
  alias MingaEditor.UI.Picker.{Context, Item}

  @doc "Captures the selected bytes before the user starts choosing a destination."
  @spec open(State.t()) :: State.t()
  def open(state) do
    case SelectionAttachment.capture(state) do
      {:ok, source} ->
        context = %{source: source}

        case candidates(Context.from_editor_state(state, context)) do
          [] ->
            NoticeWorkflow.publish(
              state,
              "Open a local Agent composer before attaching a selection."
            )

          [_ | _] ->
            PickerUI.open(state, __MODULE__, context)
        end

      {:error, :no_selection} ->
        NoticeWorkflow.publish(state, "Select text before attaching it.")

      {:error, :selection_too_large} ->
        NoticeWorkflow.publish(state, "Select at most 32 KiB of text to attach.")

      {:error, :source_unavailable} ->
        NoticeWorkflow.publish(state, "The selected text is no longer available.")
    end
  end

  @impl true
  @spec title() :: String.t()
  def title, do: "Attach selection snapshot to Agent"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{
        tab_bar: %TabBar{workspaces: workspaces},
        picker_ui: %{context: %{source: source}}
      }) do
    for %Workspace{
          id: id,
          label: label,
          payload: %Agent{
            agent_ui: %UIState{draft_save: %DraftSave{target: target, request: {:ready, _, _}}}
          }
        } <- workspaces do
      %Item{
        id: {id, target},
        label: label,
        description: "Selection snapshot",
        meta: %{source: source}
      }
    end
  end

  def candidates(_context), do: []

  @impl true
  @spec on_select(Item.t(), State.t()) :: State.t()
  def on_select(%Item{id: {owner, target}, meta: %{source: source}}, state),
    do: DraftWorkflow.attach_selection(state, owner, target, source)

  def on_select(_item, state), do: state
end
