defmodule MingaAgent.SessionHooksSuppressionTest do
  # Mutates global Options and the test provider override to verify hook dispatch behavior.
  use ExUnit.Case, async: false

  alias Minga.Config.Options
  alias MingaAgent.Hooks.RecordingHook
  alias MingaAgent.Session

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

  test "hooks_enabled false suppresses lifecycle and prompt hook dispatch for inline sessions" do
    normal = start_supervised_session(hooks_enabled?: true, persist?: true)
    :sys.get_state(normal)
    assert_receive {:agent_hook_payload, %{"event" => "SessionStart"}}, 1_000
    assert :ok = Session.send_prompt(normal, "hello")
    assert_receive {:agent_hook_payload, %{"event" => "UserPromptSubmit"}}, 1_000
    flush_hook_messages()

    inline = start_supervised_session(hooks_enabled?: false, persist?: false)
    :sys.get_state(inline)
    assert :ok = Session.send_prompt(inline, "hello")

    refute_receive {:agent_hook_payload, %{"event" => "SessionStart"}}, 100
    refute_receive {:agent_hook_payload, %{"event" => "UserPromptSubmit"}}, 100
  end

  defp start_supervised_session(opts) do
    start_supervised!(
      {Session,
       [
         provider: Minga.Test.StubProvider,
         provider_opts: [provider: :test, model: "test"]
       ] ++ opts},
      id: {:session_hooks_suppression, make_ref()}
    )
  end

  defp flush_hook_messages do
    receive do
      {:agent_hook_payload, _payload} -> flush_hook_messages()
    after
      0 -> :ok
    end
  end

  defp restore_provider(nil), do: Application.delete_env(:minga, :test_provider_module)

  defp restore_provider(provider),
    do: Application.put_env(:minga, :test_provider_module, provider)
end
