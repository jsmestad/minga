defmodule MingaAgent.Gateway.JsonRpcTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Gateway.JsonRpc

  # These tests exercise the pure dispatch function without WebSocket
  # machinery. They require the Tool.Registry and SessionManager to
  # be running (started by the application supervisor).

  describe "dispatch/1" do
    test "runtime.capabilities returns a capabilities manifest" do
      request =
        JSON.encode!(%{jsonrpc: "2.0", method: "runtime.capabilities", params: %{}, id: 1})

      {:ok, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["id"] == 1
      assert is_map(response["result"])
      assert is_integer(response["result"]["tool_count"])
      assert is_integer(response["result"]["session_count"])
      assert is_list(response["result"]["features"])
      assert is_binary(response["result"]["version"])
    end

    test "runtime.describe_tools returns tool list" do
      request =
        JSON.encode!(%{jsonrpc: "2.0", method: "runtime.describe_tools", params: %{}, id: 2})

      {:ok, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["id"] == 2
      assert is_list(response["result"])
    end

    test "runtime.describe_sessions returns session list" do
      request =
        JSON.encode!(%{jsonrpc: "2.0", method: "runtime.describe_sessions", params: %{}, id: 3})

      {:ok, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["id"] == 3
      assert is_list(response["result"])
    end

    test "session.list returns session descriptions" do
      request = JSON.encode!(%{jsonrpc: "2.0", method: "session.list", params: %{}, id: 4})
      {:ok, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["id"] == 4
      assert is_list(response["result"])
    end

    test "tool.list returns tool descriptions" do
      request = JSON.encode!(%{jsonrpc: "2.0", method: "tool.list", params: %{}, id: 5})
      {:ok, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["id"] == 5
      assert is_list(response["result"])
    end

    test "params field is optional for parameterless methods" do
      request = JSON.encode!(%{jsonrpc: "2.0", method: "runtime.capabilities", id: 10})
      {:ok, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["id"] == 10
      assert is_map(response["result"])
    end

    test "unknown method returns method_not_found error" do
      request = JSON.encode!(%{jsonrpc: "2.0", method: "bogus.method", params: %{}, id: 6})
      {:error, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["id"] == 6
      assert response["error"]["code"] == -32_601
      assert response["error"]["message"] =~ "Method not found"
      assert response["error"]["message"] =~ "bogus.method"
    end

    test "malformed JSON returns parse error" do
      {:error, response_json} = JsonRpc.dispatch("not json at all {{{")
      response = JSON.decode!(response_json)

      assert response["error"]["code"] == -32_700
      assert response["error"]["message"] =~ "Parse error"
    end

    test "missing jsonrpc field returns invalid request" do
      request = JSON.encode!(%{method: "runtime.capabilities", id: 7})
      {:error, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["error"]["code"] == -32_600
    end

    test "notification (no id) returns :notification" do
      request = JSON.encode!(%{jsonrpc: "2.0", method: "runtime.capabilities", params: %{}})
      assert :notification == JsonRpc.dispatch(request)
    end

    test "session.stop without session_id returns invalid params" do
      request = JSON.encode!(%{jsonrpc: "2.0", method: "session.stop", params: %{}, id: 8})
      {:error, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["error"]["code"] == -32_602
      assert response["error"]["message"] =~ "session_id"
    end

    test "session.prompt without required params returns invalid params" do
      request = JSON.encode!(%{jsonrpc: "2.0", method: "session.prompt", params: %{}, id: 9})
      {:error, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["error"]["code"] == -32_602
    end

    test "tool.execute without required params returns invalid params" do
      request =
        JSON.encode!(%{
          jsonrpc: "2.0",
          method: "tool.execute",
          params: %{"name" => "foo"},
          id: 11
        })

      {:error, response_json} = JsonRpc.dispatch(request)
      response = JSON.decode!(response_json)

      assert response["error"]["code"] == -32_602
    end
  end
end
