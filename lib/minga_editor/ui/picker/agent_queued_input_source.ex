defmodule MingaEditor.UI.Picker.AgentQueuedInputSource do
  @moduledoc "Lists pending inputs and confirms withdrawal of one exact queued revision."

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.Session
  alias Minga.Core.Plural
  alias MingaAgent.Session.QueuedInputSummary
  alias MingaAgent.FileMention
  alias MingaEditor.Agent.{PromptInput, QuestionResponse, QueuedInputEdit}
  alias MingaEditor.PickerUI
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.UI.Picker.{AgentQueuedInputWithdrawal, Context, Item, Source}

  @type origin :: PromptInput.submission_owner()
  @typep operation ::
           :read_queue
           | {:withdraw_queued_input, QueuedInputSummary.identity()}
           | {:read_queued_input_text, QueuedInputSummary.identity()}
           | {:edit_queued_input, QueuedInputSummary.identity(), String.t()}
  @typep request :: (operation() -> Session.composer_result())

  @doc "Opens the queue inspector without modifying the current composer."
  @spec open(State.t()) :: State.t()
  def open(state) do
    with {_, _, _} = origin <- current_origin(state),
         {:ok, request} <- request(state, origin) do
      PickerUI.open(state, __MODULE__, %{origin: origin, request: request})
    else
      _unavailable ->
        NoticeWorkflow.publish(state, "Open a saved Agent conversation to inspect its queue.")
    end
  end

  @doc "Identifies the active saved conversation, not the currently selected queue row."
  @spec current_origin(State.t()) :: origin() | nil
  def current_origin(
        %State{workspace: %{agent_ui: %{connection: %{persistent_drafts?: true}}}} = state
      ) do
    PromptInput.submission_owner(
      Runtime.review_scope(state.shell_runtime),
      state.workspace.agent_ui
    )
  end

  def current_origin(_state), do: nil

  @impl true
  @spec title() :: String.t()
  def title, do: "Queued Agent inputs"

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_context), do: []

  @impl true
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{picker_ui: %{context: %{origin: origin, confirm: entry}}}) do
    {:ok,
     [
       %Item{id: {:keep, origin}, label: "Keep queued input"},
       %Item{
         id: {:edit, origin, entry.identity},
         label: "Edit queued input",
         description: entry_label(entry)
       },
       %Item{
         id: {:withdraw, origin, entry.identity},
         label: "Withdraw queued input",
         description: entry_label(entry)
       }
     ], %{status: "This does not change the composer draft."}}
  end

  def async_fetch(%Context{picker_ui: %{context: %{origin: origin, request: request}}}) do
    case request.(:read_queue) do
      {:ok, []} ->
        {:ok, [], %{status: "No pending inputs in this conversation."}}

      {:ok, entries} when is_list(entries) ->
        items = Enum.map(entries, &item(&1, origin))
        {:ok, items, %{status: "Select a queued input to edit or withdraw."}}

      {:error, _reason} ->
        {:error, "Queue unavailable. Reconnect to the original Agent conversation."}
    end
  catch
    :exit, _reason -> {:error, "The original Agent conversation disconnected."}
  end

  @impl true
  @spec on_select(Item.t(), State.t()) :: State.t()
  def on_select(%Item{id: {:confirm, origin, %QueuedInputSummary{} = entry}}, state) do
    case current_origin(state) do
      ^origin -> PickerUI.open(state, __MODULE__, %{origin: origin, confirm: entry})
      _changed -> stale(state)
    end
  end

  def on_select(%Item{id: {:keep, origin}}, state) do
    case current_origin(state) do
      ^origin -> open(state)
      _changed -> stale(state)
    end
  end

  def on_select(%Item{id: {:withdraw, origin, identity}}, state) do
    with ^origin <- current_origin(state),
         {:ok, request} <- request(state, origin) do
      AgentQueuedInputWithdrawal.start(state, origin, fn ->
        request.({:withdraw_queued_input, identity})
      end)
    else
      _changed -> stale(state)
    end
  end

  def on_select(%Item{id: {:edit, origin, identity}}, state) do
    with ^origin <- current_origin(state),
         {:ok, request} <- request(state, origin) do
      QueuedInputEdit.open(state, origin, identity, fn
        current_identity, :read -> request.({:read_queued_input_text, current_identity})
        current_identity, {:save, text} -> request.({:edit_queued_input, current_identity, text})
      end)
    else
      _changed -> stale(state)
    end
  end

  def on_select(_item, state), do: state

  @spec request(State.t(), origin()) :: {:ok, request()} | :unavailable
  defp request(_state, {_workspace, session, record}) when node(session) == node() do
    root = Minga.Project.workspace_root()

    {:ok,
     fn
       :read_queue ->
         # minga:allow-blocking — closure runs in an EffectScheduler worker, not the Editor
         Session.queued_input_summaries(session, record)

       {:withdraw_queued_input, identity} ->
         Session.change_queued_input(session, record, identity, :remove)

       {:read_queued_input_text, identity} ->
         # minga:allow-blocking — closure runs in an EffectScheduler worker, not the Editor
         Session.queued_input_text(session, record, identity)

       {:edit_queued_input, identity, text} ->
         # minga:allow-blocking — closure runs in the QueuedInputEdit effect under EffectScheduler, not in the Editor
         selection = Session.model_selection(session)

         with {:ok, resolved} <-
                FileMention.resolve_prompt(text, root, model_selection: selection) do
           Session.change_queued_input(
             session,
             record,
             identity,
             {:replace_prompt, text, resolved}
           )
         end
     end}
  end

  defp request(state, {_workspace, session, record}) do
    case QuestionResponse.remote_authority(state, session, self()) do
      {_driver, _receipt} = authority ->
        {:ok, fn operation -> SessionClient.composer({session, record}, authority, operation) end}

      _without_authority ->
        :unavailable
    end
  end

  @spec item(QueuedInputSummary.t(), origin()) :: Item.t()
  defp item(entry, origin) do
    %Item{
      id: {:confirm, origin, entry},
      label: entry_label(entry),
      description: Plural.count(entry.attachment_count, "attachment", "attachments")
    }
  end

  @spec entry_label(QueuedInputSummary.t()) :: String.t()
  defp entry_label(%QueuedInputSummary{kind: kind, preview: preview}) do
    name = if kind == :steering, do: "Steer", else: "Follow-up"

    case preview |> String.replace(~r/[\x00-\x1f\x7f-\x9f]/u, " ") |> String.trim() do
      "" -> "#{name}: Attachment-only input"
      text -> "#{name}: #{text}"
    end
  end

  @spec stale(State.t()) :: State.t()
  defp stale(state),
    do: NoticeWorkflow.publish(state, "The Agent conversation changed. Queue untouched.")
end
