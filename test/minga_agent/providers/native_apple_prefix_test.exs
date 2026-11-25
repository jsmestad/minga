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

  # A stand-in for the Apple tokenizer: one token per four bytes of each candidate prompt,
  # plus a fixed cost per declared tool. It reports what it was asked to count.
  defp counter(owner) do
    fn texts, candidates, tools, reserve ->
      send(owner, {:counted, Enum.map(tools, & &1.name), reserve, length(texts), candidates})

      counts =
        for candidate <- candidates do
          text = Enum.map_join(candidate, "\n\n", &Enum.at(texts, &1))
          div(byte_size(text), 4) + 250 * length(tools)
        end

      {:ok, %{counts: counts, context: 4_096}}
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

    await_preview(pid, :current)
  end

  # An Apple prefix that is not counted yet answers `{:pending, token}`; the provider
  # sends the preview to its owner when the count ends.
  defp await_preview(pid, operation) do
    token = make_ref()

    case GenServer.call(pid, {:preview_prefix, token, operation}) do
      {:pending, ^token} ->
        assert_receive {:prefix_preview_ready, ^token, reply}, 2_000
        reply

      reply ->
        reply
    end
  end

  # A counter that reports each start and counts only when the test lets it.
  defp held_counter(owner) do
    count = counter(owner)

    fn texts, candidates, tools, reserve ->
      send(owner, {:counting, self()})

      receive do
        :count -> count.(texts, candidates, tools, reserve)
        {:fail, reason} -> {:error, reason}
      end
    end
  end

  defp start_apple(root, counter) do
    start_supervised!(
      {Native,
       subscriber: self(),
       model_selection: apple_selection(),
       project_root: root,
       apple_counter: counter,
       skip_api_key_env: true},
      id: make_ref()
    )
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
        # One count covers every candidate, with the compact tool set and reserve a dispatch sends.
        assert_received {:counted, tools, 512, parts, candidates}
        refute_received {:counted, _tools, _reserve, _parts, _candidates}
        assert Enum.sort(tools) == ~w(edit_file find grep read_file write_file)

        if text,
          do: assert({parts, candidates} == {3, [[0, 1], [0, 1, 2]]}),
          else: assert({parts, candidates} == {2, [[0, 1]]})
      else
        refute_received {:counted, _tools, _reserve, _parts, _candidates}
      end
    end
  end

  test "an Apple prefix that cannot fit its reserve refuses with Apple's counts", %{tmp_dir: dir} do
    root = project(dir, "project", nil)

    oversized = fn _texts, candidates, _tools, _reserve ->
      {:ok, %{counts: Enum.map(candidates, fn _candidate -> 3_700 end), context: 4_096}}
    end

    assert {:error, message} = preview(apple_selection(), root, oversized)

    assert message ==
             "Apple Intelligence (On Device) cannot hold its fixed instructions and tools: Apple counts 3,700 tokens, plus 512 reserved for the response, over its 4,096-token context. A new conversation will not help; choose a model with a larger context"
  end

  test "an unchanged Apple prefix is counted once", %{tmp_dir: dir} do
    pid = start_apple(project(dir, "project", @rules), counter(self()))

    assert {:ok, _prefix, token, :ok} = await_preview(pid, :current)
    assert :ok = GenServer.call(pid, {:commit_prefix_preview, token})
    assert_received {:counted, _tools, _reserve, _parts, _candidates}

    assert {:ok, _prefix, _token, :ok} =
             GenServer.call(pid, {:preview_prefix, make_ref(), :current})

    refute_received {:counted, _tools, _reserve, _parts, _candidates}
  end

  test "a preview never waits for the count: it answers pending, then the count's result", %{
    tmp_dir: dir
  } do
    pid = start_apple(project(dir, "project", @rules), held_counter(self()))
    token = make_ref()

    # The count has not been let through, so an answer here cannot have waited for it.
    assert {:pending, ^token} = GenServer.call(pid, {:preview_prefix, token, :current})
    assert_receive {:counting, counting}
    refute_received {:prefix_preview_ready, _token, _reply}

    send(counting, :count)
    assert_receive {:prefix_preview_ready, ^token, {:ok, %Prefix{}, ^token, :ok}}
    assert :ok = GenServer.call(pid, {:commit_prefix_preview, token})
  end

  test "one count is in flight for a prefix, however many times it is asked for", %{tmp_dir: dir} do
    pid = start_apple(project(dir, "project", @rules), held_counter(self()))

    GenServer.cast(pid, {:warm_prefix, self(), :current})
    GenServer.cast(pid, {:warm_prefix, self(), :current})
    token = make_ref()
    assert {:pending, ^token} = GenServer.call(pid, {:preview_prefix, token, :current})

    assert_receive {:counting, counting}
    refute_received {:counting, _second}

    send(counting, :count)
    assert_receive {:prefix_preview_ready, ^token, {:ok, %Prefix{}, ^token, :ok}}
    assert_received {:counted, _tools, _reserve, _parts, _candidates}
    refute_received {:counted, _tools, _reserve, _parts, _candidates}
  end

  test "a prefix warmed before the first send is ready when that send asks", %{tmp_dir: dir} do
    pid = start_apple(project(dir, "project", @rules), held_counter(self()))

    GenServer.cast(pid, {:warm_prefix, self(), :current})
    assert_receive {:counting, counting}
    send(counting, :count)
    monitor = Process.monitor(counting)
    assert_receive {:DOWN, ^monitor, :process, ^counting, _reason}

    assert {:ok, %Prefix{}, _token, :ok} =
             GenServer.call(pid, {:preview_prefix, make_ref(), :current})

    refute_received {:counting, _again}
  end

  test "a count that ends after its waiter left is kept for the next preview", %{tmp_dir: dir} do
    pid = start_apple(project(dir, "project", @rules), held_counter(self()))
    token = make_ref()
    assert {:pending, ^token} = GenServer.call(pid, {:preview_prefix, token, :current})
    assert_receive {:counting, counting}

    # A Stop during admission discards the waiter; the count goes on.
    GenServer.cast(pid, {:discard_prefix_preview, token, self()})
    send(counting, :count)
    monitor = Process.monitor(counting)
    assert_receive {:DOWN, ^monitor, :process, ^counting, _reason}

    assert {:ok, %Prefix{}, _token, :ok} =
             GenServer.call(pid, {:preview_prefix, make_ref(), :current})

    refute_received {:prefix_preview_ready, ^token, _reply}
    refute_received {:counting, _again}
  end

  test "a count that fails, or whose process dies, answers the waiter with a refusal and keeps nothing",
       %{tmp_dir: dir} do
    for failure <- [:reported, :killed] do
      pid = start_apple(project(dir, "project-#{failure}", @rules), held_counter(self()))
      token = make_ref()
      assert {:pending, ^token} = GenServer.call(pid, {:preview_prefix, token, :current})
      assert_receive {:counting, counting}

      case failure do
        :reported -> send(counting, {:fail, :apple_count_timeout})
        :killed -> Process.exit(counting, :kill)
      end

      assert_receive {:prefix_preview_ready, ^token, {:error, message}}
      assert message =~ "Apple Intelligence (On Device)"

      assert message =~ "counting its fixed instructions and tools" or
               message =~ "could not count"

      # Nothing was kept, so the next preview counts again.
      assert {:pending, _token} = GenServer.call(pid, {:preview_prefix, make_ref(), :current})
      assert_receive {:counting, _again}
    end
  end

  test "a second preview while one waits for its count is refused", %{tmp_dir: dir} do
    pid = start_apple(project(dir, "project", @rules), held_counter(self()))
    assert {:pending, _token} = GenServer.call(pid, {:preview_prefix, make_ref(), :current})

    assert {:error, :prefix_transition_active} =
             GenServer.call(pid, {:preview_prefix, make_ref(), :current})
  end
end
