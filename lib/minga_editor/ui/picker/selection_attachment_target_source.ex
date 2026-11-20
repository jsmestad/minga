defmodule MingaEditor.UI.Picker.SelectionAttachmentTargetSource do
  @moduledoc "Chooses the exact saved Agent draft that receives an explicitly captured selection."

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.DraftAttachment
  alias MingaEditor.Agent.{DraftSave, DraftWorkflow, SelectionAttachment, UIState}
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.{Agent, RemoteSession}
  alias MingaEditor.UI.Picker.{Context, Item}

  @doc "Captures the selected bytes before the user starts choosing a destination."
  @spec open(State.t()) :: State.t()
  def open(state), do: open_snapshot(state, SelectionAttachment.capture(state))

  @doc "Captures the current buffer before the user starts choosing a destination."
  @spec open_buffer(State.t()) :: State.t()
  def open_buffer(state), do: open_snapshot(state, SelectionAttachment.capture_buffer(state))

  @spec open_snapshot(
          State.t(),
          {:ok, SelectionAttachment.source()} | {:error, SelectionAttachment.rejection()}
        ) ::
          State.t()
  defp open_snapshot(state, captured) do
    case captured do
      {:ok, snapshot} ->
        context = %{source: snapshot}

        case candidates(Context.from_editor_state(state, context)) do
          [] ->
            NoticeWorkflow.publish(
              state,
              "Open a saved Agent composer before attaching a snapshot."
            )

          [_ | _] ->
            PickerUI.open(state, __MODULE__, context)
        end

      {:error, :no_selection} ->
        NoticeWorkflow.publish(state, "Select text before attaching it.")

      {:error, :source_too_large} ->
        NoticeWorkflow.publish(state, "Attach at most 32 KiB of text.")

      {:error, :empty_buffer} ->
        NoticeWorkflow.publish(state, "The current buffer is empty.")

      {:error, :source_unavailable} ->
        NoticeWorkflow.publish(state, "The attachment source is no longer available.")
    end
  end

  @impl true
  @spec title() :: String.t()
  def title, do: "Attach snapshot to Agent"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{
        tab_bar: %TabBar{workspaces: workspaces},
        picker_ui: %{context: %{source: {kind, _, _, _} = source}}
      }) do
    for %Workspace{
          id: id,
          label: label,
          payload: %Agent{
            remote_session: remote,
            agent_ui: %UIState{draft_save: %DraftSave{target: target, request: {:ready, _, _}}}
          }
        } <- workspaces,
        label = destination_label(label, remote, target),
        is_binary(label) do
      %Item{
        id: {id, target},
        label: label,
        description: DraftAttachment.snapshot_label(kind),
        meta: %{source: source}
      }
    end
  end

  def candidates(_context), do: []

  @spec destination_label(String.t(), RemoteSession.t() | nil, DraftSave.target()) ::
          String.t() | nil
  defp destination_label(label, nil, {session, _record}) when node(session) == node(), do: label

  defp destination_label(
         _label,
         %RemoteSession{server_name: server, session_id: record, connection_status: :connected},
         {_session, record}
       ),
       do: "[#{server}] #{record}"

  defp destination_label(_label, _remote, _target), do: nil

  @impl true
  @spec on_select(Item.t(), State.t()) :: State.t()
  def on_select(%Item{id: {owner, target}, meta: %{source: source}}, state),
    do: DraftWorkflow.attach_text(state, owner, target, source)

  def on_select(_item, state), do: state
end
