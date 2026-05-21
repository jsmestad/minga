defmodule MingaEditor.InlineAsk.Events do
  @moduledoc """
  Routes ephemeral agent session events into inline ask state.
  """

  alias MingaAgent.EphemeralSession
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineAsk

  @type state :: EditorState.t()

  @doc "Returns true when a session belongs to an inline ask."
  @spec session?(state(), pid()) :: boolean()
  def session?(%{shell_state: %{inline_asks: asks}}, session_pid)
      when is_map(asks) and is_pid(session_pid) do
    InlineAsk.session?(asks, session_pid)
  end

  def session?(_state, _session_pid), do: false

  @doc "Handles an agent event emitted by an inline ask session."
  @spec handle_event(state(), pid(), term()) :: state()
  def handle_event(state, session_pid, event) when is_pid(session_pid) do
    update_for_session(state, session_pid, fn ask -> apply_event(ask, session_pid, event) end)
  end

  @doc "Handles the async result of sending the inline ask prompt."
  @spec handle_prompt_result(state(), pid(), term()) :: state()
  def handle_prompt_result(state, _session_pid, :ok), do: state

  def handle_prompt_result(state, session_pid, {:error, reason}) do
    EphemeralSession.stop(session_pid)

    update_for_session(state, session_pid, fn ask ->
      InlineAsk.fail(ask, "Failed to ask: #{inspect(reason)}")
    end)
  end

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

  @spec update_for_session(state(), pid(), (InlineAsk.t() -> InlineAsk.t())) :: state()
  defp update_for_session(%{shell_state: %{inline_asks: asks}} = state, session_pid, fun) do
    {buffer_pid, ask} = find_by_session(asks, session_pid)

    case ask do
      %InlineAsk{} -> put_inline_asks(state, Map.put(asks, buffer_pid, fun.(ask)))
      nil -> state
    end
  end

  defp update_for_session(state, _session_pid, _fun), do: state

  @spec find_by_session(InlineAsk.store(), pid()) :: {pid() | nil, InlineAsk.t() | nil}
  defp find_by_session(asks, session_pid) do
    Enum.find(asks, {nil, nil}, fn {_buffer_pid, ask} -> ask.session_pid == session_pid end)
  end

  @spec put_inline_asks(state(), InlineAsk.store()) :: state()
  defp put_inline_asks(state, asks) do
    EditorState.set_inline_asks(state, asks)
  end
end
