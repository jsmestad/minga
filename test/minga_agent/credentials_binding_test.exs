defmodule MingaAgent.CredentialsBindingTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.ApiKey
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.ContinuationCodec
  alias MingaAgent.Session.PrefixStore
  alias MingaAgent.Test.ModelSelectionFixture

  @moduletag :tmp_dir

  test "dispatch and continuity use the same exact selected material without persisting it", %{
    tmp_dir: dir
  } do
    opts = [config_dir: dir, env: %{"OPENAI_API_KEY" => "unselected-environment-key"}]
    credential = ApiKey.new("openai", :file)
    assert :ok = Credentials.store("openai", "selected-file-secret", opts)
    assert {:ok, first} = Credentials.bind_request(credential, nil, opts)
    assert {:ok, same} = Credentials.bind_request(credential, first, opts)
    assert first.identity == same.identity
    refute inspect(first) =~ "selected-file-secret"

    selection = ModelSelectionFixture.selection(credential: credential)

    assert {:ok, request_options} =
             ReqLLMAdapter.stream_opts(selection, [], %MingaAgent.Config{}, same.material)

    assert request_options[:api_key] == "selected-file-secret"
    assert request_options[:max_retries] == 0
    refute request_options[:api_key] == "unselected-environment-key"
    identity = ModelSelection.replay_identity(selection, same.identity)
    assert {:ok, prefix} = PrefixStore.candidate("instructions", [], identity)
    assert {:ok, :applied, continuation} = Continuation.change_prefix(Continuation.new(), prefix)
    encoded = JSON.encode!(ContinuationCodec.encode(continuation))
    refute encoded =~ "selected-file-secret"
    refute encoded =~ "access_token"
    refute encoded =~ dir
  end

  test "replacement changes the volatile binding and restarting its owner cannot prove continuity",
       %{tmp_dir: dir} do
    opts = [config_dir: dir, env: %{"OPENAI_API_KEY" => nil}]
    credential = ApiKey.new("openai", :file)
    assert :ok = Credentials.store("openai", "first-secret", opts)
    assert {:ok, first} = Credentials.bind_request(credential, nil, opts)
    assert :ok = Credentials.store("openai", "replacement-secret", opts)
    assert {:ok, replacement} = Credentials.bind_request(credential, first, opts)
    refute replacement.identity == first.identity
    assert {:ok, unchanged} = Credentials.bind_request(credential, replacement, opts)
    assert unchanged.identity == replacement.identity
    assert {:ok, restarted} = Credentials.bind_request(credential, nil, opts)
    refute restarted.identity == unchanged.identity
  end
end
