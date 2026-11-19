defmodule MingaAgent.OAuth.FlowTest do
  # Uses global registered flow processes, so tests must serialize.
  use ExUnit.Case, async: false

  alias MingaAgent.OAuth.Flow
  alias MingaAgent.OAuth.PendingFlow

  describe "manual paste-back flow" do
    test "complete_manual succeeds with a full redirect URL and reuses the authorize port" do
      {:ok, url, ref} = Flow.begin_manual(timeout_ms: 60_000)

      state =
        url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

      pasted = "http://localhost:1455/auth/callback?code=full_code&state=#{state}"
      parent = self()

      exchange_fun = fn code, verifier, port ->
        send(parent, {:exchange, code, verifier, port})
        {:ok, %{access: "access", refresh: nil, expires: nil, account_id: nil}}
      end

      write_fun = fn tokens ->
        send(parent, {:write, tokens})
        :ok
      end

      assert {:ok, :openai} =
               Flow.complete_manual(ref, pasted, exchange_fun: exchange_fun, write_fun: write_fun)

      assert_receive {:exchange, "full_code", verifier, 1455}
      assert is_binary(verifier)
      assert_receive {:write, %{access: "access"}}
    end

    test "complete_manual accepts a bare authorization code" do
      {:ok, _url, ref} = Flow.begin_manual(timeout_ms: 60_000)

      assert {:ok, :openai} =
               Flow.complete_manual(ref, "bare_code",
                 exchange_fun: token_exchange(self()),
                 write_fun: token_writer(self())
               )

      assert_receive {:exchange_code, "bare_code"}
    end

    test "complete_manual accepts code#state and code&state blobs" do
      assert_manual_blob_complete("hash_code#")
      assert_manual_blob_complete("amp_code&")
    end

    test "complete_manual rejects a state mismatch" do
      {:ok, _url, ref} = Flow.begin_manual(timeout_ms: 60_000)

      assert {:error, message} = Flow.complete_manual(ref, "code#wrong-state")
      assert message =~ "state mismatch"
      assert message =~ "possible CSRF"
    end

    test "only the owning remote client and session can consume a manual flow" do
      owner = self()
      other = start_supervised!({Agent, fn -> nil end})

      {:ok, _url, ref} =
        Flow.begin_manual(session_id: "session-a", client_pid: owner, timeout_ms: 60_000)

      opts = [exchange_fun: token_exchange(owner), write_fun: token_writer(owner)]

      for identity <- [
            [],
            [session_id: "session-a", client_pid: other],
            [session_id: "session-b", client_pid: owner]
          ] do
        assert {:error, message} = Flow.complete_manual(ref, "code", identity ++ opts)
        assert message =~ "different remote session"
      end

      refute_received {:exchange_code, _}
      refute_received {:write_tokens, _}

      owner_opts = [session_id: "session-a", client_pid: owner] ++ opts
      assert {:ok, :openai} = Flow.complete_manual(ref, "code", owner_opts)
      assert_received {:exchange_code, "code"}
      assert_received {:write_tokens, %{access: "access"}}

      assert {:error, message} = Flow.complete_manual(ref, "code", owner_opts)
      assert message =~ "Unknown OAuth flow"
      refute_received {:exchange_code, _}
      refute_received {:write_tokens, _}
    end

    test "complete_manual rejects expired and unknown flow refs clearly" do
      {:ok, _url, ref} = Flow.begin_manual(timeout_ms: 60_000)
      assert :ok = PendingFlow.expire(ref)

      assert {:error, expired} = Flow.complete_manual(ref, "code")
      assert expired =~ "expired"

      assert {:error, unknown} = Flow.complete_manual("missing-ref", "code")
      assert unknown =~ "Unknown OAuth flow"
    end

    test "pending flow entries remain typed structs through put and take" do
      entry = PendingFlow.Entry.new("verifier", "state", 1455, "session-a", self())

      assert {:ok, ref} = PendingFlow.put(entry, 60_000)

      assert {:ok, {stored, nil, nil}} =
               PendingFlow.take(ref, session_id: "session-a", client_pid: self())

      assert %PendingFlow.Entry{} = stored
      assert stored.verifier == "verifier"
      assert stored.state == "state"
      assert stored.port == 1455
      assert stored.owner_session_id == "session-a"
      assert stored.owner_client_pid == self()
    end

    test "a mismatched operation cannot consume the bound fallback writer" do
      entry = PendingFlow.Entry.new("verifier", "state", 1455, "session-a", self())
      operation_ref = make_ref()
      writer = fn _tokens -> :ok end
      owner = [session_id: "session-a", client_pid: self()]

      assert {:ok, ref} =
               PendingFlow.put(entry, 60_000, operation_ref: operation_ref, write_fun: writer)

      assert {:error, :wrong_operation} = PendingFlow.take(ref, owner)

      assert {:error, :wrong_operation} =
               PendingFlow.take(ref, Keyword.put(owner, :operation_ref, make_ref()))

      assert {:ok, {^entry, ^writer, ^operation_ref}} =
               PendingFlow.take(ref, Keyword.put(owner, :operation_ref, operation_ref))

      assert {:error, :unknown_flow} =
               PendingFlow.take(ref, Keyword.put(owner, :operation_ref, operation_ref))
    end

    test "complete_manual reports denied authorization" do
      {:ok, _url, ref} = Flow.begin_manual(timeout_ms: 60_000)
      pasted = "http://localhost:1455/auth/callback?error=access_denied&error_description=Nope"

      assert {:error, message} = Flow.complete_manual(ref, pasted)
      assert message =~ "Authorization failed"
      assert message =~ "Nope"
    end
  end

  test "cancelling while the browser launcher blocks releases the listener and registration" do
    parent = self()
    operation = make_ref()

    launch = fn url ->
      query = URI.decode_query(URI.parse(url).query)
      port = URI.parse(query["redirect_uri"]).port
      send(parent, {:launching, self(), port})

      receive do
        :release -> :ok
      end
    end

    first = Task.async(fn -> Flow.run(operation_ref: operation, launch_fun: launch) end)
    assert_receive {:launching, helper, port}, 1_000
    monitor = Process.monitor(helper)
    send(first.pid, {:connection_cancelled, operation})
    assert {:error, :cancelled} = Task.await(first, 1_000)

    # The launcher can exit before it processes the monitor signal from this test process.
    assert_receive {:DOWN, ^monitor, :process, ^helper, reason}
    assert reason in [:killed, :noproc]
    refute Process.whereis(:minga_oauth_flow)

    replacement = make_ref()
    # A new flow must bind the same callback port, not silently fall back to the other port.
    second = Task.async(fn -> Flow.run(operation_ref: replacement, launch_fun: launch) end)
    assert_receive {:launching, _helper, ^port}, 1_000
    send(second.pid, {:connection_cancelled, replacement})
    assert {:error, :cancelled} = Task.await(second, 1_000)
  end

  describe "registration" do
    test "only one flow can register at a time" do
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(self(), :minga_oauth_flow)

      task =
        Task.async(fn ->
          case Process.whereis(:minga_oauth_flow) do
            nil -> :available
            _pid -> :already_running
          end
        end)

      assert Task.await(task) == :already_running
    after
      try do
        Process.unregister(:minga_oauth_flow)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  @spec assert_manual_blob_complete(String.t()) :: :ok
  defp assert_manual_blob_complete(blob_prefix) do
    {:ok, url, ref} = Flow.begin_manual(timeout_ms: 60_000)
    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    blob = blob_prefix <> state

    assert {:ok, :openai} =
             Flow.complete_manual(ref, blob,
               exchange_fun: token_exchange(self()),
               write_fun: token_writer(self())
             )

    :ok
  end

  @spec token_exchange(pid()) ::
          (String.t(), String.t(), pos_integer() -> {:ok, MingaAgent.OAuth.token_response()})
  defp token_exchange(parent) do
    fn code, _verifier, _port ->
      send(parent, {:exchange_code, code})
      {:ok, %{access: "access", refresh: nil, expires: nil, account_id: nil}}
    end
  end

  @spec token_writer(pid()) :: (MingaAgent.OAuth.token_response() -> :ok)
  defp token_writer(parent) do
    fn tokens ->
      send(parent, {:write_tokens, tokens})
      :ok
    end
  end
end
