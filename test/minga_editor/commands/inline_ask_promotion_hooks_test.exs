defmodule MingaEditor.Commands.InlineAskPromotionHooksTest do
  # Mutates global Options and the test provider override while exercising the real session manager.
  use Minga.Test.EditorCase, async: false

  alias Minga.Config.Options
  alias MingaAgent.Hooks.RecordingHook
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaEditor.Commands.InlineAsk, as: InlineAskCommand
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.InlineAsk

  @moduletag :tmp_dir

  setup do
    previous_hooks = Options.get(:agent_hooks)
    previous_provider = Application.get_env(:minga, :test_provider_module)
    RecordingHook.set_recipient(self())
    Application.put_env(:minga, :test_provider_module, Minga.Test.StubProvider)

    hooks = [
      %{event: "SessionStart", type: :module, module: RecordingHook, function: :record},
      %{event: "UserPromptSubmit", type: :module, module: RecordingHook, function: :record}
    ]

    assert {:ok, ^hooks} = Options.set(:agent_hooks, hooks)

    on_exit(fn ->
      Options.set(:agent_hooks, previous_hooks)
      restore_provider(previous_provider)
      RecordingHook.clear_recipient()
    end)

    :ok
  end

  test "promoting an inline ask seeds a workspace without dispatching SessionStart hooks", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "lib/demo.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "hello")
    ctx = start_editor("hello", file_path: path, project_root: dir)

    state = InlineAskCommand.open(editor_state(ctx))

    ask =
      state
      |> active_ask(ctx.buffer)
      |> InlineAsk.append_input("What is this?")
      |> InlineAsk.append_response("A demo.")
      |> InlineAsk.answered()

    state = InlineAskCommand.promote(state, ask)
    session = AgentAccess.session(state)
    assert is_pid(session)
    on_exit(fn -> SessionManager.stop_session_by_pid(session) end)
    :sys.get_state(session)

    refute_receive {:agent_hook_payload, %{"event" => "SessionStart"}}, 100

    assert :ok = Session.send_prompt(session, "follow up")
    assert_receive {:agent_hook_payload, %{"event" => "UserPromptSubmit"}}, 1_000
    assert active_ask(state, ctx.buffer) == nil
  end

  defp active_ask(state, buffer) do
    state |> EditorState.inline_asks() |> InlineAsk.active(buffer)
  end

  defp restore_provider(nil), do: Application.delete_env(:minga, :test_provider_module)

  defp restore_provider(provider),
    do: Application.put_env(:minga, :test_provider_module, provider)
end
