defmodule MingaEditor.InlineAsk.Events do
  @moduledoc """
  Routes ephemeral agent session events into inline ask state.

  This is the ask variant adapter over the shared
  `MingaEditor.InlineOverlay.Events` framework: it supplies the store
  accessor/setter and the ask-specific event transitions, and delegates
  the session lookup and write-back plumbing to the framework.
  """

  alias MingaAgent.EphemeralSession
  alias MingaEditor.InlineOverlay.Events, as: Overlay
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineAsk

  @type state :: EditorState.t()

  @doc "Returns true when a session belongs to an inline ask."
  @spec session?(state(), pid()) :: boolean()
  def session?(state, session_pid), do: Overlay.session?(state, session_pid, spec())

  @doc "Handles an agent event emitted by an inline ask session."
  @spec handle_event(state(), pid(), term()) :: state()
  def handle_event(state, session_pid, event) when is_pid(session_pid) do
    Overlay.handle_event(state, session_pid, event, spec(), &apply_event/3)
  end

  @doc "Handles the async result of sending the inline ask prompt."
  @spec handle_prompt_result(state(), pid(), term()) :: state()
  def handle_prompt_result(state, session_pid, result) do
    Overlay.handle_prompt_result(state, session_pid, result, spec(), &fail/2)
  end

  @spec spec() :: Overlay.spec()
  defp spec do
    %{
      store: &inline_asks/1,
      replace: &MingaEditor.Shell.Traditional.Workflow.install_inline_ask/2,
      session?: &InlineAsk.session?/2
    }
  end

  @spec inline_asks(state()) :: InlineAsk.store()
  defp inline_asks(%{
         shell_runtime: %MingaEditor.Shell.Runtime{
           state: %MingaEditor.Shell.Traditional.State{} = shell_state
         }
       }),
       do: MingaEditor.Shell.Traditional.State.inline_asks(shell_state)

  defp inline_asks(%EditorState{}), do: %{}

  @spec fail(InlineAsk.t(), term()) :: InlineAsk.t()
  defp fail(%InlineAsk{} = ask, reason),
    do: InlineAsk.fail(ask, "Failed to ask: #{inspect(reason)}")

  @spec apply_event(InlineAsk.t(), pid(), term()) :: InlineAsk.t()
  defp apply_event(%InlineAsk{} = ask, _session_pid, {:text_delta, text}),
    do: InlineAsk.append_response(ask, text)

  defp apply_event(%InlineAsk{} = ask, _session_pid, {:status_changed, :thinking}),
    do: InlineAsk.mark_thinking(ask)

  defp apply_event(%InlineAsk{} = ask, _session_pid, {:status_changed, :tool_executing}),
    do: InlineAsk.mark_thinking(ask)

  defp apply_event(%InlineAsk{} = ask, session_pid, {:status_changed, :idle}) do
    response = EphemeralSession.assistant_response(session_pid)
    EphemeralSession.stop(session_pid)

    ask =
      if response == "" or String.contains?(ask.response, response),
        do: ask,
        else: InlineAsk.append_response(ask, response)

    InlineAsk.answered(ask)
  end

  defp apply_event(%InlineAsk{} = ask, session_pid, {:error, message}) do
    EphemeralSession.stop(session_pid)
    InlineAsk.fail(ask, message)
  end

  defp apply_event(%InlineAsk{} = ask, _session_pid, _event), do: ask
end
