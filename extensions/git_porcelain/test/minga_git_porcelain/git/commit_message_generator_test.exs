defmodule MingaGitPorcelain.Git.CommitMessageGeneratorTest do
  use ExUnit.Case, async: true

  alias MingaGitPorcelain.Git.CommitMessageGenerator

  # Every test isolates the credential store and OAuth file so a developer's own sign-ins cannot add routes.
  @moduletag :tmp_dir

  @diff "diff --git a/lib/a.ex b/lib/a.ex\n+def a, do: :ok\n"

  setup %{tmp_dir: dir} do
    test_pid = self()

    capture = fn reply ->
      fn model, messages, opts ->
        send(test_pid, {:request, model, messages, opts})
        reply
      end
    end

    %{
      capture: capture,
      env_credentials: [
        config_dir: dir,
        oauth_path: Path.join(dir, "oauth.json"),
        env: %{"OPENAI_API_KEY" => "fixture-openai-key"}
      ]
    }
  end

  test "requests through the sanctioned AI API with resolved model and credentials", ctx do
    client = ctx.capture.({:ok, stream_response(["feat(a): add a", "\n"])})

    assert {:ok, "feat(a): add a"} = CommitMessageGenerator.generate(@diff, ai_opts(client, ctx))

    assert_receive {:request, %LLMDB.Model{id: "gpt-4"},
                    [%{role: "system", content: system}, %{role: "user", content: @diff}],
                    request_opts}

    assert system =~ "conventional commit format"
    assert request_opts[:max_tokens] == 300
    assert request_opts[:api_key] == "fixture-openai-key"
  end

  test "uses credentials from Minga's credential store", %{tmp_dir: dir} = ctx do
    credentials_opts = [
      config_dir: dir,
      oauth_path: Path.join(dir, "oauth.json"),
      env: %{"OPENAI_API_KEY" => nil}
    ]

    :ok = MingaAgent.Credentials.store("openai", "stored-openai-key", credentials_opts)
    client = ctx.capture.({:error, :stop})

    assert {:error, "AI generation failed: :stop"} =
             CommitMessageGenerator.generate(@diff,
               model: "openai:gpt-4",
               client: client,
               credentials_opts: credentials_opts
             )

    assert_receive {:request, _model, _messages, request_opts}
    assert request_opts[:api_key] == "stored-openai-key"
  end

  test "an empty response keeps the empty-message error", ctx do
    client = ctx.capture.({:ok, stream_response(["  \n"])})

    assert {:error, "AI returned an empty commit message"} =
             CommitMessageGenerator.generate(@diff, ai_opts(client, ctx))
  end

  test "a provider failure keeps the generation-failed error", ctx do
    client = ctx.capture.({:error, :rate_limited})

    assert {:error, "AI generation failed: :rate_limited"} =
             CommitMessageGenerator.generate(@diff, ai_opts(client, ctx))
  end

  test "an unresolvable model fails before any request", ctx do
    client = fn _model, _messages, _opts -> flunk("unexpected request") end

    assert {:error, "AI generation failed: {:model_not_found, " <> _rest} =
             CommitMessageGenerator.generate(@diff,
               model: "private:custom-model",
               client: client,
               credentials_opts: ctx.env_credentials
             )
  end

  @spec ai_opts(function(), map()) :: keyword()
  defp ai_opts(client, ctx) do
    [model: "openai:gpt-4", client: client, credentials_opts: ctx.env_credentials]
  end

  @spec stream_response([String.t()]) :: ReqLLM.StreamResponse.t()
  defp stream_response(chunks) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{usage: %{}, finish_reason: :stop}
      end)

    %ReqLLM.StreamResponse{
      stream: Enum.map(chunks, &ReqLLM.StreamChunk.text/1),
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: nil,
      context: ReqLLM.Context.new()
    }
  end
end
