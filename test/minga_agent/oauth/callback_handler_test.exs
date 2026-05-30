defmodule MingaAgent.OAuth.CallbackHandlerTest do
  # Uses the global registered process name :minga_oauth_flow, so tests must serialize.
  use ExUnit.Case, async: false

  import Plug.Test

  alias MingaAgent.OAuth.CallbackHandler

  describe "GET /auth/callback" do
    test "sends code and state to registered flow process" do
      Process.register(self(), :minga_oauth_flow)

      conn =
        conn(:get, "/auth/callback?code=test_code&state=test_state")
        |> CallbackHandler.call(CallbackHandler.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "Received"
      assert_receive {:oauth_callback, "test_code", "test_state"}, 1000
    after
      safe_unregister(:minga_oauth_flow)
    end

    test "sends error message when code is missing and returns 400" do
      Process.register(self(), :minga_oauth_flow)

      conn =
        conn(:get, "/auth/callback?state=test_state")
        |> CallbackHandler.call(CallbackHandler.init([]))

      assert conn.status == 400
      assert conn.resp_body =~ "Missing authorization code"
      assert_receive {:oauth_callback_error, :missing_code}, 1000
    after
      safe_unregister(:minga_oauth_flow)
    end

    test "sends provider error details when OpenAI redirects with an error" do
      Process.register(self(), :minga_oauth_flow)

      conn =
        conn(:get, "/auth/callback?error=access_denied&error_description=Nope")
        |> CallbackHandler.call(CallbackHandler.init([]))

      assert conn.status == 400
      assert conn.resp_body =~ "access_denied"
      assert conn.resp_body =~ "Nope"
      assert_receive {:oauth_callback_error, {:provider_error, "access_denied: Nope"}}, 1000
    after
      safe_unregister(:minga_oauth_flow)
    end

    test "does not crash when no flow process is registered" do
      conn =
        conn(:get, "/auth/callback?code=orphan&state=orphan")
        |> CallbackHandler.call(CallbackHandler.init([]))

      assert conn.status == 200
    end

    test "handles missing state gracefully" do
      Process.register(self(), :minga_oauth_flow)

      conn =
        conn(:get, "/auth/callback?code=the_code")
        |> CallbackHandler.call(CallbackHandler.init([]))

      assert conn.status == 200
      assert_receive {:oauth_callback, "the_code", nil}, 1000
    after
      safe_unregister(:minga_oauth_flow)
    end
  end

  describe "GET /callback" do
    test "keeps the previous callback path as a compatibility alias" do
      Process.register(self(), :minga_oauth_flow)

      conn =
        conn(:get, "/callback?code=legacy_code&state=legacy_state")
        |> CallbackHandler.call(CallbackHandler.init([]))

      assert conn.status == 200
      assert_receive {:oauth_callback, "legacy_code", "legacy_state"}, 1000
    after
      safe_unregister(:minga_oauth_flow)
    end
  end

  describe "unmatched routes" do
    test "returns 404 for unknown paths" do
      conn =
        conn(:get, "/unknown")
        |> CallbackHandler.call(CallbackHandler.init([]))

      assert conn.status == 404
    end
  end

  describe "Bandit integration" do
    test "serves callback over HTTP" do
      Process.register(self(), :minga_oauth_flow)

      {:ok, pid} =
        Bandit.start_link(
          plug: CallbackHandler,
          port: 0,
          ip: {127, 0, 0, 1},
          thousand_island_options: [num_acceptors: 1]
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

      {:ok, resp} =
        Req.get("http://127.0.0.1:#{port}/auth/callback?code=http_code&state=http_state")

      assert resp.status == 200
      assert resp.body =~ "Received"
      assert_receive {:oauth_callback, "http_code", "http_state"}, 1000

      Supervisor.stop(pid, :normal)
    after
      safe_unregister(:minga_oauth_flow)
    end
  end

  defp safe_unregister(name) do
    Process.unregister(name)
  rescue
    ArgumentError -> :ok
  end
end
