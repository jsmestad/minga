defmodule MingaAgent.Session.ApplePrefixDisclosureTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials
  alias MingaAgent.Session
  alias MingaAgent.Test.ModelSelectionFixture

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    File.mkdir_p!(Path.join(root, ".git"))

    File.write!(
      Path.join(root, "AGENTS.md"),
      String.duplicate("Always follow this rule.\n", 3_000)
    )

    env = Map.new(Credentials.known_providers(), &{Credentials.env_var_for(&1), nil})
    credential_opts = [config_dir: dir, oauth_path: Path.join(dir, "oauth.json"), env: env]

    # Counts one token per four bytes of system text, as a stand-in for the Apple tokenizer.
    counter = fn [system | _rest], _tools, _reserve ->
      [%{text: text}] = system.content
      {:ok, %{instructions: div(byte_size(text), 4), transcript: 1, context: 4_096}}
    end

    session =
      start_supervised!(
        {Session,
         provider: MingaAgent.Providers.Native,
         provider_opts: [
           credential_opts: credential_opts,
           project_root: root,
           apple_counter: counter,
           model_resolver_opts:
             ModelSelectionFixture.resolver_opts()
             |> Keyword.delete(:credential_snapshot)
             |> Keyword.put(:apple_availability_fn, fn -> {:ok, 4_096} end)
         ],
         persist?: false,
         hooks_enabled?: false,
         session_start_hook_enabled?: false,
         recover_interrupted_work?: false},
        id: make_ref()
      )

    %{session: session}
  end

  test "selecting Apple with oversized project instructions says they are not sent", %{
    session: session
  } do
    notice =
      "Apple Intelligence (On Device) is not sending the project instruction files: they do not fit its context with room for the conversation. Choose a model with a larger context to use them."

    refute notice in system_messages(session)
    assert :ok = Session.set_model(session, "apple:system")
    assert Enum.count(system_messages(session), &(&1 == notice)) == 1
  end

  defp system_messages(session) do
    for {:system, text, _level} <- Session.messages(session), do: text
  end
end
