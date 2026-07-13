defmodule MingaEditor.InlineEdit.Events do
  @moduledoc """
  Routes ephemeral agent session events into inline edit state.

  This is the edit variant adapter over the shared
  `MingaEditor.InlineOverlay.Events` framework: it supplies the store
  accessor/setter and the edit-specific event transitions, and delegates
  the session lookup and write-back plumbing to the framework.
  """

  alias MingaAgent.EphemeralSession
  alias MingaEditor.InlineOverlay.Events, as: Overlay
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineEdit

  @type state :: EditorState.t()

  @doc "Returns true when a session belongs to an inline edit."
  @spec session?(state(), pid()) :: boolean()
  def session?(state, session_pid), do: Overlay.session?(state, session_pid, spec())

  @doc "Handles an agent event emitted by an inline edit session."
  @spec handle_event(state(), pid(), term()) :: state()
  def handle_event(state, session_pid, event) when is_pid(session_pid) do
    Overlay.handle_event(state, session_pid, event, spec(), &apply_event/3)
  end

  @doc "Handles the async result of sending the inline edit prompt."
  @spec handle_prompt_result(state(), pid(), term()) :: state()
  def handle_prompt_result(state, session_pid, result) do
    Overlay.handle_prompt_result(state, session_pid, result, spec(), &fail/2)
  end

  @spec spec() :: Overlay.spec()
  defp spec do
    %{
      store: &store/1,
      set_store: &EditorState.set_inline_edits/2,
      session?: &InlineEdit.session?/2
    }
  end

  @spec store(state()) :: InlineEdit.store() | nil
  defp store(%{shell_runtime: %{state: %{inline_edits: edits}}}) when is_map(edits), do: edits
  defp store(_state), do: nil

  @spec fail(InlineEdit.t(), term()) :: InlineEdit.t()
  defp fail(%InlineEdit{} = edit, reason),
    do: InlineEdit.fail(edit, "Failed to rewrite: #{inspect(reason)}")

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
end
