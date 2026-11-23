defmodule MingaAgent.Providers.NativeApplePrefixTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelResolver
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session.Prefix
  alias MingaAgent.Test.ModelSelectionFixture

  @moduletag :tmp_dir

  @rules "PROJECT RULE 3911"

  # A stand-in for the Apple tokenizer: one token per four bytes of system text, plus a
  # fixed cost per declared tool. It reports what it was asked to count.
  defp counter(owner) do
    fn [%{role: :system} = system, %{role: :user}], tools, reserve ->
      [%{text: text}] = system.content
      send(owner, {:counted, Enum.map(tools, & &1.name), reserve})

      {:ok,
       %{
         instructions: div(byte_size(text), 4) + 250 * length(tools),
         transcript: 1,
         context: 4_096
       }}
    end
  end

  defp apple_selection do
    {:ok, selection} =
      ModelResolver.resolve("apple:system",
        backend_spec: MingaAgent.ProviderPacks.Native.spec(),
        credential_snapshot: Snapshot.new(%{}, nil),
        config: %AgentConfig{},
        require_apple_ready: true,
        apple_selection_readiness: {:ok, 4_096}
      )

    selection
  end

  defp preview(selection, root, counter) do
    pid =
      start_supervised!(
        {Native,
         subscriber: self(),
         model_selection: selection,
         project_root: root,
         apple_counter: counter,
         credential_opts: [env: %{"OPENAI_API_KEY" => "synthetic-key"}],
         skip_api_key_env: true},
        id: make_ref()
      )

    GenServer.call(pid, {:preview_prefix, make_ref(), :current})
  end

  defp project(dir, name, instructions) do
    root = Path.join(dir, name)
    File.mkdir_p!(Path.join(root, ".git"))
    if instructions, do: File.write!(Path.join(root, "AGENTS.md"), instructions)
    root
  end

  for {name, route, instructions, omitted?} <- [
        {"catalog route, large instructions", :catalog, :large, false},
        {"catalog route, no instructions", :catalog, nil, false},
        {"Apple route, small instructions", :apple, :small, false},
        {"Apple route, large instructions", :apple, :large, true},
        {"Apple route, no instructions", :apple, nil, false}
      ] do
    test "prefix policy: #{name}", %{tmp_dir: dir} do
      text =
        case unquote(instructions) do
          :large -> @rules <> "\n" <> String.duplicate("Always follow this rule.\n", 3_000)
          :small -> @rules
          nil -> nil
        end

      root = project(dir, "project", text)

      selection =
        if unquote(route) == :apple,
          do: apple_selection(),
          else: ModelSelectionFixture.selection()

      assert {:ok, %Prefix{} = prefix, _token, :ok} = preview(selection, root, counter(self()))

      if unquote(omitted?) do
        assert prefix.omitted == [:instructions]
        refute prefix.instructions =~ @rules

        assert Prefix.omission_notice(prefix, "Apple Intelligence (On Device)") ==
                 "Apple Intelligence (On Device) is not sending the project instruction files: they do not fit its context with room for the conversation. Choose a model with a larger context to use them."
      else
        assert prefix.omitted == []
        assert Prefix.omission_notice(prefix, "any") == nil
        if text, do: assert(prefix.instructions =~ @rules)
      end

      if unquote(route) == :apple do
        # The count uses the same compact tool set and output reserve a dispatch sends.
        assert_received {:counted, tools, 512}
        assert Enum.sort(tools) == ~w(edit_file find grep read_file write_file)
      else
        refute_received {:counted, _tools, _reserve}
      end
    end
  end

  test "an Apple prefix that cannot fit its reserve refuses with Apple's counts", %{tmp_dir: dir} do
    root = project(dir, "project", nil)

    oversized = fn _messages, _tools, _reserve ->
      {:ok, %{instructions: 3_700, transcript: 3_710, context: 4_096}}
    end

    assert {:error, message} = preview(apple_selection(), root, oversized)

    assert message ==
             "Apple Intelligence (On Device) cannot hold its fixed instructions and tools: Apple counts 3,700 tokens, plus 512 reserved for the response, over its 4,096-token context. A new conversation will not help; choose a model with a larger context"
  end

  test "an unchanged Apple prefix is counted once", %{tmp_dir: dir} do
    root = project(dir, "project", @rules)

    pid =
      start_supervised!(
        {Native,
         subscriber: self(),
         model_selection: apple_selection(),
         project_root: root,
         apple_counter: counter(self()),
         skip_api_key_env: true}
      )

    assert {:ok, _prefix, token, :ok} =
             GenServer.call(pid, {:preview_prefix, make_ref(), :current})

    assert :ok = GenServer.call(pid, {:commit_prefix_preview, token})
    assert_received {:counted, _tools, _reserve}

    assert {:ok, _prefix, _token, :ok} =
             GenServer.call(pid, {:preview_prefix, make_ref(), :current})

    refute_received {:counted, _tools, _reserve}
  end
end
