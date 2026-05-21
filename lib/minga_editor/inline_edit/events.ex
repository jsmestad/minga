defmodule MingaEditor.InlineEdit.Events do
  @moduledoc """
  Routes ephemeral agent session events into inline edit state.
  """

  alias MingaAgent.EphemeralSession
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineEdit

  @type state :: EditorState.t()

  @doc "Returns true when a session belongs to an inline edit."
  @spec session?(state(), pid()) :: boolean()
  def session?(%{shell_state: %{inline_edits: edits}}, session_pid)
      when is_map(edits) and is_pid(session_pid) do
    InlineEdit.session?(edits, session_pid)
  end

  def session?(_state, _session_pid), do: false

  @doc "Handles an agent event emitted by an inline edit session."
  @spec handle_event(state(), pid(), term()) :: state()
  def handle_event(state, session_pid, event) when is_pid(session_pid) do
    update_for_session(state, session_pid, fn edit -> apply_event(edit, session_pid, event) end)
  end

  @doc "Handles the async result of sending the inline edit prompt."
  @spec handle_prompt_result(state(), pid(), term()) :: state()
  def handle_prompt_result(state, _session_pid, :ok), do: state

  def handle_prompt_result(state, session_pid, {:error, reason}) do
    EphemeralSession.stop(session_pid)

    update_for_session(state, session_pid, fn edit ->
      InlineEdit.fail(edit, "Failed to rewrite: #{inspect(reason)}")
    end)
  end

  @spec apply_event(InlineEdit.t(), pid(), term()) :: InlineEdit.t()
  defp apply_event(
         %InlineEdit{} = edit,
         _session_pid,
         {:tool_ended, "produce_rewrite", replacement, :done}
       )
       when is_binary(replacement),
       do: InlineEdit.set_proposal(edit, replacement)

  defp apply_event(%InlineEdit{} = edit, _session_pid, {:text_delta, text}),
    do: InlineEdit.append_proposal(edit, text)

  defp apply_event(%InlineEdit{} = edit, _session_pid, {:status_changed, :thinking}),
    do: InlineEdit.mark_thinking(edit)

  defp apply_event(%InlineEdit{} = edit, _session_pid, {:status_changed, :tool_executing}),
    do: InlineEdit.mark_thinking(edit)

  defp apply_event(%InlineEdit{} = edit, session_pid, {:status_changed, :idle}) do
    response = EphemeralSession.assistant_response(session_pid)
    EphemeralSession.stop(session_pid)

    edit = maybe_append_assistant_response(edit, response)

    InlineEdit.proposed(edit)
  end

  defp apply_event(%InlineEdit{} = edit, session_pid, {:error, message}) do
    EphemeralSession.stop(session_pid)
    InlineEdit.fail(edit, message)
  end

  defp apply_event(%InlineEdit{} = edit, _session_pid, _event), do: edit

  @spec maybe_append_assistant_response(InlineEdit.t(), String.t()) :: InlineEdit.t()
  defp maybe_append_assistant_response(%InlineEdit{proposal_source: :tool} = edit, _response),
    do: edit

  defp maybe_append_assistant_response(%InlineEdit{proposed_rewrite: proposed} = edit, _response)
       when proposed != "",
       do: edit

  defp maybe_append_assistant_response(%InlineEdit{} = edit, ""), do: edit

  defp maybe_append_assistant_response(%InlineEdit{} = edit, response),
    do: InlineEdit.append_proposal(edit, response)

  @spec update_for_session(state(), pid(), (InlineEdit.t() -> InlineEdit.t())) :: state()
  defp update_for_session(%{shell_state: %{inline_edits: edits}} = state, session_pid, fun) do
    {buffer_pid, edit} = find_by_session(edits, session_pid)

    case edit do
      %InlineEdit{} -> EditorState.set_inline_edits(state, Map.put(edits, buffer_pid, fun.(edit)))
      nil -> state
    end
  end

  defp update_for_session(state, _session_pid, _fun), do: state

  @spec find_by_session(InlineEdit.store(), pid()) :: {pid() | nil, InlineEdit.t() | nil}
  defp find_by_session(edits, session_pid) do
    Enum.find(edits, {nil, nil}, fn {_buffer_pid, edit} -> edit.session_pid == session_pid end)
  end
end
