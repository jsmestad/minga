defmodule MingaEditor.Agent.SubagentPeekComposer do
  @moduledoc "Keeps each child's draft and correlates sends without touching the parent composer."

  alias Minga.Buffer.Document
  alias MingaAgent.SessionManager
  alias MingaEditor.State
  alias MingaEditor.State.Windows
  alias MingaEditor.Window

  @type target :: {Window.id(), SessionManager.foreground_identity()}
  @type edit ::
          {:insert, String.t()}
          | :backspace
          | :delete
          | {:move_to, Document.position()}
          | {:move, :left | :right | :up | :down}
  @typep draft :: %{
           text: Document.t(),
           submission: {reference(), String.t()} | nil,
           notice: String.t() | nil
         }
  @type t :: %__MODULE__{
          focused: target() | nil,
          drafts: %{SessionManager.foreground_identity() => draft()}
        }

  defstruct focused: nil, drafts: %{}

  @doc "Returns the currently focused child identity only while the matching pane stays active."
  @spec focused(State.t()) :: target() | nil
  def focused(state) do
    case state.agent_connection.peek_composer.focused do
      {window_id, identity} = target ->
        case Windows.active_struct(state.workspace.windows) do
          %Window{id: ^window_id, content: {:subagent_peek, {_, ^identity}}} -> target
          _other -> nil
        end

      nil ->
        nil
    end
  end

  @doc "Focuses the composer for the exact displayed child."
  @spec focus(State.t(), target()) :: State.t()
  def focus(state, {window_id, identity} = target) do
    case Windows.active_struct(state.workspace.windows) do
      %Window{id: ^window_id, content: {:subagent_peek, {_, ^identity}}} ->
        composer = state.agent_connection.peek_composer
        State.install_subagent_peek_composer(state, %{composer | focused: target})

      _other ->
        state
    end
  end

  @doc "Returns to inspection without altering any draft."
  @spec blur(State.t()) :: State.t()
  def blur(state) do
    case state.agent_connection.peek_composer do
      %__MODULE__{focused: nil} -> state
      composer -> State.install_subagent_peek_composer(state, %{composer | focused: nil})
    end
  end

  @doc "Returns the draft, cursor and admission notice for this child."
  @spec presentation(t(), SessionManager.foreground_identity()) ::
          {String.t(), Document.position(), boolean(), String.t() | nil}
  def presentation(%__MODULE__{} = composer, identity) do
    case Map.fetch(composer.drafts, identity) do
      {:ok, draft} ->
        {Document.content(draft.text), Document.cursor(draft.text), draft.submission != nil,
         draft.notice}

      :error ->
        {"", {0, 0}, false, nil}
    end
  end

  @doc "Edits only the child composer that owns focus."
  @spec edit(State.t(), target(), edit()) :: State.t()
  def edit(state, {_, identity} = target, operation) do
    if focused(state) == target do
      draft = draft(state, identity)
      replace_draft(state, identity, %{draft | text: edit_document(draft.text, operation)})
    else
      state
    end
  end

  @doc "Sends this exact draft to its owning child, rechecking authority in SessionManager."
  @spec submit(State.t(), target()) :: State.t()
  def submit(state, {_, identity} = target) do
    if focused(state) == target do
      case draft(state, identity) do
        %{submission: nil} = draft -> send_draft(state, identity, draft)
        %{submission: {_token, _submitted_text}} -> state
      end
    else
      state
    end
  end

  @doc "A send receipts the exact snapshot, not whatever text is currently in the active pane."
  @spec sent(State.t(), SessionManager.foreground_identity(), reference(), term()) :: State.t()
  def sent(state, identity, token, result) do
    case Map.get(state.agent_connection.peek_composer.drafts, identity) do
      %{submission: {^token, submitted}} = draft ->
        replace_draft(state, identity, finish(draft, submitted, result))

      _stale ->
        state
    end
  end

  @spec draft(State.t(), SessionManager.foreground_identity()) :: draft()
  defp draft(state, identity) do
    case Map.fetch(state.agent_connection.peek_composer.drafts, identity) do
      {:ok, draft} -> draft
      :error -> %{text: Document.new(), submission: nil, notice: nil}
    end
  end

  @spec replace_draft(State.t(), SessionManager.foreground_identity(), draft()) :: State.t()
  defp replace_draft(state, identity, draft) do
    composer = state.agent_connection.peek_composer

    State.install_subagent_peek_composer(state, %{
      composer
      | drafts: Map.put(composer.drafts, identity, draft)
    })
  end

  @spec edit_document(Document.t(), edit()) :: Document.t()
  defp edit_document(document, {:insert, text}), do: Document.insert_text(document, text)
  defp edit_document(document, :backspace), do: Document.delete_before(document)
  defp edit_document(document, :delete), do: Document.delete_at(document)
  defp edit_document(document, {:move_to, position}), do: Document.move_to(document, position)
  defp edit_document(document, {:move, direction}), do: Document.move(document, direction)

  @spec send_draft(State.t(), SessionManager.foreground_identity(), draft()) :: State.t()
  defp send_draft(state, identity, draft) do
    text = Document.content(draft.text)

    if String.trim(text) == "" do
      state
    else
      token = make_ref()
      editor = self()
      manager = state.agent_connection.session_manager

      work = fn ->
        send(editor, {:subagent_peek_sent, identity, token, deliver(manager, identity, text)})
      end

      case Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, work) do
        {:ok, _pid} ->
          replace_draft(state, identity, %{draft | submission: {token, text}, notice: nil})

        {:error, reason} ->
          replace_draft(state, identity, %{draft | notice: refusal(reason)})
      end
    end
  end

  @spec deliver(GenServer.server(), SessionManager.foreground_identity(), String.t()) :: term()
  defp deliver(manager, identity, content) do
    SessionManager.send_foreground_subagent_prompt(manager, identity, content)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec finish(draft(), String.t(), term()) :: draft()
  defp finish(%{text: text} = draft, submitted, result)
       when result in [:ok, {:queued, :steering}] do
    if Document.content(text) == submitted do
      %{draft | text: Document.new(), submission: nil, notice: nil}
    else
      %{
        draft
        | submission: nil,
          notice: "Message sent. Edits made while sending stayed in the draft."
      }
    end
  end

  defp finish(draft, _submitted, {:error, reason}),
    do: %{draft | submission: nil, notice: refusal(reason)}

  @spec refusal(term()) :: String.t()
  defp refusal(:subagent_initial_request_active),
    do: "The subagent is still working on its brief. Draft kept."

  defp refusal(reason)
       when reason in [:subagent_stopped, :subagent_unavailable, :session_id_changed],
       do: "This subagent is no longer available. Draft kept."

  defp refusal(:subagent_send_indeterminate),
    do: "Delivery unconfirmed. Check the subagent conversation before sending again. Draft kept."

  defp refusal(reason), do: "Could not message this subagent: #{inspect(reason)}. Draft kept."
end
