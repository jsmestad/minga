defmodule MingaAgent.Session.PrefixColdRuntimeTest do
  # A real child BEAM uses erl_child_setup; serialize OS-process resources to avoid EPIPE.
  use ExUnit.Case, async: false

  @moduletag timeout: 30_000

  alias MingaAgent.ModelSelection
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.ContinuationCodec
  alias MingaAgent.Session.Outcome
  alias MingaAgent.Session.PrefixStore
  alias MingaAgent.Test.ModelSelectionFixture
  alias ReqLLM.Context

  @tag :tmp_dir
  test "a fresh runtime restores prefix and retained output tags before constructors load", %{
    tmp_dir: tmp_dir
  } do
    owner_name = "unloaded_extension_" <> Base.encode16(:crypto.strong_rand_bytes(12))
    owner = String.to_atom(owner_name)

    spec =
      MingaAgent.Tool.Spec.new!(
        source: {:extension, owner},
        name: "extension_lookup",
        description: "Inspect a fixture",
        parameter_schema: %{},
        callback: fn _args -> {:ok, "fixture"} end
      )

    tool = MingaAgent.Providers.Native.ReqLLMAdapter.tool(spec, nil, %{minga_tool_spec: spec})
    declaration = MingaAgent.Providers.Native.ReqLLMAdapter.declaration(tool)
    assert declaration.source == {:extension, owner_name}
    continuation = completed_candidate(declaration)

    output = %{
      "output_version" => 1,
      "view" => "one line",
      "capture" => %{"status" => "complete"},
      "selection" => %{
        "kind" => "full",
        "unit" => "lines",
        "start" => 0,
        "count" => 1,
        "total" => 1
      },
      "presentation" => %{"status" => "complete"},
      "reference" => nil,
      "revision" => %{
        "source_kind" => "disk",
        "source_id" => "fixture",
        "scope" => %{
          "kind" => "full",
          "unit" => "bytes",
          "start" => 0,
          "count" => 8,
          "total" => 8
        },
        "sha256" => String.duplicate("a", 64),
        "generation" => nil
      },
      "attachments" => []
    }

    path = Path.join(tmp_dir, "cold-prefix.json")

    File.write!(
      path,
      JSON.encode!(%{
        continuation: ContinuationCodec.encode(continuation),
        output: output,
        absent_owner: owner_name,
        epoch_id: continuation.prefixes.selected
      })
    )

    script = """
    Application.put_all_env(Config.Reader.read!("config/config.exs", env: :test))
    {:ok, _} = Application.ensure_all_started(:minga)
    fixture = JSON.decode!(File.read!(hd(System.argv())))
    owner_absent? = fn ->
      try do
        String.to_existing_atom(fixture["absent_owner"])
        false
      rescue
        ArgumentError -> true
      end
    end
    true = owner_absent?.()
    {:ok, _} = MingaAgent.Tool.Output.Codec.decode(fixture["output"])
    {:ok, restored} = MingaAgent.Session.ContinuationCodec.decode(fixture["continuation"])
    true = map_size(restored.prefixes.epochs) == 1
    expected_epoch = fixture["epoch_id"]
    ^expected_epoch = restored.prefixes.selected
    true = MingaAgent.Session.ContinuationCodec.encode(restored)["messages"] ==
      fixture["continuation"]["messages"]
    prefix = MingaAgent.Session.PrefixStore.resolve(restored.prefixes, restored.prefixes.selected)
    [%{source: {:extension, owner}}] = prefix.schemas
    true = owner == fixture["absent_owner"]
    adapter = MingaAgent.Providers.Native.ReqLLMAdapter
    schemas = MingaAgent.Tool.Registry.all()
      |> Enum.map(fn spec -> adapter.tool(spec, nil, %{minga_tool_spec: spec}) end)
      |> adapter.declarations()
    {:ok, changed} = MingaAgent.Session.PrefixStore.candidate(prefix, prefix.instructions,
      schemas, prefix.identity, prefix.skills)
    {:error, {:portable_context_transition_required, _}} =
      MingaAgent.Session.Continuation.change_prefix(restored, changed)
    true = owner_absent?.()
    IO.puts("cold-restored")
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {result, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2"] ++ paths ++ ["-e", script, path],
        stderr_to_stdout: true
      )

    assert status == 0, result
    assert result =~ "cold-restored"
  end

  defp completed_candidate(schema) do
    selection =
      ModelSelectionFixture.selection(request_provider: :openai_codex, model_id: "gpt-6.1-sol")

    identity =
      ModelSelection.replay_identity(
        selection,
        %{kind: :oauth, account_id: "fixture-account", source_id: String.duplicate("a", 64)}
      )

    {:ok, prefix} = PrefixStore.candidate("extension instructions", [schema], identity)
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)
    {:ok, request, active} = Continuation.begin_request(initial, "request-1", 1, "first")
    outcome = Outcome.new(request, request.messages ++ [Context.assistant("answer")])
    {:ok, continuation} = Continuation.complete(active, outcome, 2)
    continuation
  end
end
