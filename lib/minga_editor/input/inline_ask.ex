defmodule MingaEditor.Input.InlineAsk do
  @moduledoc """
  Input handler for the active inline ask overlay.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaAgent.EphemeralSession
  alias MingaEditor.Commands.InlineAsk, as: InlineAskCommand
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineAsk

  @type state :: MingaEditor.Input.Handler.handler_state()

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{buffers: %{active: buffer_pid}}} = state, codepoint, _modifiers)
      when is_pid(buffer_pid) do
    ask = state |> EditorState.inline_asks() |> InlineAsk.active(buffer_pid)

    case ask do
      %InlineAsk{} -> {:handled, handle_inline_key(state, ask, codepoint)}
      nil -> {:passthrough, state}
    end
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  @impl true
  @spec handle_mouse(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _cc), do: {:passthrough, state}

  @spec handle_inline_key(state(), InlineAsk.t(), non_neg_integer()) :: state()
  defp handle_inline_key(state, ask, 27), do: dismiss(state, ask)

  defp handle_inline_key(state, %InlineAsk{status: :answered} = ask, 9),
    do: InlineAskCommand.promote(state, ask)

  defp handle_inline_key(state, %InlineAsk{status: status} = ask, ?j)
       when status in [:answered, :error],
       do: update_ask(state, InlineAsk.scroll(ask, 1))

  defp handle_inline_key(state, %InlineAsk{status: status} = ask, ?k)
       when status in [:answered, :error],
       do: update_ask(state, InlineAsk.scroll(ask, -1))

  defp handle_inline_key(state, %InlineAsk{status: :input} = ask, 13), do: submit(state, ask)

  defp handle_inline_key(state, %InlineAsk{status: :input} = ask, 127),
    do: update_ask(state, InlineAsk.backspace(ask))

  defp handle_inline_key(state, %InlineAsk{status: :input} = ask, 8),
    do: update_ask(state, InlineAsk.backspace(ask))

  defp handle_inline_key(state, %InlineAsk{status: :input} = ask, codepoint)
       when codepoint >= 32 do
    update_ask(state, InlineAsk.append_input(ask, <<codepoint::utf8>>))
  end

  defp handle_inline_key(state, _ask, _codepoint), do: state

  @spec submit(state(), InlineAsk.t()) :: state()
  defp submit(state, %InlineAsk{prompt: ""}),
    do: EditorState.set_status(state, "Type a question first")

  defp submit(state, %InlineAsk{} = ask) do
    case EphemeralSession.ask(InlineAsk.agent_prompt(ask), project_root(state),
           subscriber: self()
         ) do
      {:ok, session_pid} ->
        update_ask(state, InlineAsk.thinking(ask, session_pid))

      {:error, reason} ->
        update_ask(state, InlineAsk.fail(ask, "Failed to start inline ask: #{inspect(reason)}"))
    end
  end

  @spec dismiss(state(), InlineAsk.t()) :: state()
  defp dismiss(state, %InlineAsk{buffer_pid: buffer_pid, session_pid: session_pid}) do
    EphemeralSession.stop(session_pid)
    {asks, _pid} = state |> EditorState.inline_asks() |> InlineAsk.dismiss(buffer_pid)
    EditorState.set_inline_asks(state, asks)
  end

  @spec update_ask(state(), InlineAsk.t()) :: state()
  defp update_ask(state, %InlineAsk{} = ask) do
    state
    |> EditorState.inline_asks()
    |> InlineAsk.put(ask)
    |> then(&EditorState.set_inline_asks(state, &1))
  end

  @spec project_root(state()) :: String.t()
  defp project_root(%{workspace: %{file_tree: %{project_root: root}}}) when is_binary(root),
    do: root

  defp project_root(%{workspace: %{file_tree: %{original_root: root}}}) when is_binary(root),
    do: root

  defp project_root(_state), do: File.cwd!()
end
