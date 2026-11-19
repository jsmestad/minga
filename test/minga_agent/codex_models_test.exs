defmodule MingaAgent.CodexModelsTest do
  use ExUnit.Case, async: true

  alias MingaAgent.CodexModels
  alias MingaAgent.ModelSelection.Credential.OAuth

  test "discovers visible model IDs using the exact pinned account" do
    credential = OAuth.new("discovery-account", "/tmp/discovery-oauth.json")

    plug = fn conn ->
      assert conn.method == "GET"
      assert conn.host == "chatgpt.com"
      assert conn.request_path == "/backend-api/codex/models"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer discovery-token"]
      assert Plug.Conn.get_req_header(conn, "chatgpt-account-id") == ["discovery-account"]

      Req.Test.json(conn, %{
        "models" => [
          %{"slug" => "listed", "visibility" => "list"},
          %{"slug" => "hidden", "visibility" => "hide"},
          %{"slug" => "unlisted", "visibility" => "none"}
        ]
      })
    end

    assert {:ok, inventory} = CodexModels.fetch(credential, oauth_resolver: &oauth/2, plug: plug)
    assert CodexModels.permits?(inventory, credential, "listed")
    refute CodexModels.permits?(inventory, credential, "hidden")
    refute CodexModels.permits?(inventory, credential, "unlisted")

    other_source = OAuth.new(credential.account_id, "/tmp/other-discovery-oauth.json")
    refute CodexModels.permits?(inventory, other_source, "listed")
  end

  test "distinguishes an empty inventory from rejection or malformed data" do
    credential = OAuth.new("discovery-account", "/tmp/discovery-oauth.json")

    assert {:ok, _inventory} = CodexModels.from_response(credential, %{"models" => []})

    assert {:error, :invalid_inventory} =
             CodexModels.from_response(credential, %{"models" => [%{"slug" => "unknown"}]})

    plug = fn conn -> Plug.Conn.send_resp(conn, 401, "private provider response") end

    assert {:error, {:http_status, 401}} =
             CodexModels.fetch(credential, oauth_resolver: &oauth/2, plug: plug)
  end

  defp oauth(:openai_codex, oauth_file: path) do
    {:ok,
     %{
       provider_key: "openai-codex",
       account_id: "discovery-account",
       oauth_file: path,
       token: "discovery-token"
     }}
  end
end
