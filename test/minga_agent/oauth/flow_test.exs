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

    test "complete_manual rejects remote owner mismatches" do
      owner = self()
      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      {:ok, _url, ref} =
        Flow.begin_manual(session_id: "session-a", client_pid: owner, timeout_ms: 60_000)

      assert {:error, message} =
               Flow.complete_manual(ref, "code", session_id: "session-a", client_pid: other)

      assert message =~ "different remote session"
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
      assert {:ok, stored} = PendingFlow.take(ref)
      assert %PendingFlow.Entry{} = stored
      assert stored.verifier == "verifier"
      assert stored.state == "state"
      assert stored.port == 1455
      assert stored.owner_session_id == "session-a"
      assert stored.owner_client_pid == self()
    end

    test "complete_manual reports denied authorization" do
      {:ok, _url, ref} = Flow.begin_manual(timeout_ms: 60_000)
      pasted = "http://localhost:1455/auth/callback?error=access_denied&error_description=Nope"

      assert {:error, message} = Flow.complete_manual(ref, pasted)
      assert message =~ "Authorization failed"
      assert message =~ "Nope"
    end
  end

  describe "registration" do
    test "only one flow can register at a time" do
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
