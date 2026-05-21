defmodule MingaEditor.InlineAsk.EditorRoutingTest do
  use Minga.Test.EditorCase, async: true

  alias MingaEditor.Commands.InlineAsk, as: InlineAskCommand
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineAsk

  @moduletag :tmp_dir

  test "agent events sent to the editor update the matching inline ask", %{tmp_dir: dir} do
    path = Path.join(dir, "lib/demo.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "hello")
    ctx = start_editor("hello", file_path: path, project_root: dir)

    session =
      start_supervised!({Agent, fn -> :ok end}, id: {:inline_ask_route_session, make_ref()})

    install_thinking_ask(ctx, session)
    send(ctx.editor, {:agent_event, session, {:text_delta, "answer"}})

    state = editor_state(ctx)
    ask = active_ask(state, ctx.buffer)
    assert ask.status == :thinking
    assert ask.response == "answer"
  end

  test "prompt send results sent to the editor mark matching inline asks failed", %{tmp_dir: dir} do
    path = Path.join(dir, "lib/demo.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "hello")
    ctx = start_editor("hello", file_path: path, project_root: dir)

    session =
      start_supervised!({Agent, fn -> :ok end},
        id: {:inline_ask_prompt_route_session, make_ref()}
      )

    install_thinking_ask(ctx, session)
    send(ctx.editor, {:inline_ask_prompt_sent, session, {:error, :provider_not_ready}})

    state = editor_state(ctx)
    ask = active_ask(state, ctx.buffer)
    assert ask.status == :error
    assert ask.response =~ "provider_not_ready"
    assert ask.session_pid == nil
  end

  defp install_thinking_ask(ctx, session) do
    :sys.replace_state(ctx.editor, fn state ->
      state = InlineAskCommand.open(state)
      ask = active_ask(state, ctx.buffer)
      asks = state |> EditorState.inline_asks() |> InlineAsk.put(InlineAsk.thinking(ask, session))
      EditorState.set_inline_asks(state, asks)
    end)
  end

  defp active_ask(state, buffer) do
    state |> EditorState.inline_asks() |> InlineAsk.active(buffer)
  end
end
