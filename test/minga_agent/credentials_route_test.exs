defmodule MingaAgent.CredentialsRouteTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials
  alias MingaAgent.Credentials.Binding
  alias MingaAgent.InferenceRoute.Credential
  alias MingaAgent.ModelSelection.Credential.RouteOwned
  alias MingaAgent.Redaction

  @secret "route-secret-value-123"

  defp opts_with(contents) do
    reader = fn _path -> {:ok, contents} end
    [credentials_reader: reader, env: %{}]
  end

  test "a route entry resolves only that route's env, dropping empty values" do
    opts =
      opts_with(%{
        "anthropic" => "sk-ant-not-for-routes",
        "routes" => %{
          "bridge" => %{"env" => %{"BRIDGE_TOKEN" => @secret, "BRIDGE_REGION" => ""}},
          "other" => %{"env" => %{"OTHER_TOKEN" => "other"}}
        }
      })

    assert {:ok, %{env: %{"BRIDGE_TOKEN" => @secret}}} =
             Credentials.route_credential("bridge", opts)

    assert {:ok, %Credential{env: env}} = Credentials.route_credential("missing", opts)
    assert env == %{}
  end

  test "binding a route-owned credential delivers the env as request material only" do
    opts = opts_with(%{"routes" => %{"bridge" => %{"env" => %{"BRIDGE_TOKEN" => @secret}}}})
    credential = RouteOwned.new("bridge", "me@example.com")

    assert {:ok, %Binding{identity: identity, material: material}} =
             Credentials.bind_request(credential, nil, opts)

    assert identity == %{kind: :route_owned, route_id: "bridge", account_ref: "me@example.com"}
    assert material == [route_credential: Credential.new(%{"BRIDGE_TOKEN" => @secret})]

    refute inspect(%Binding{identity: identity, material: material}) =~ @secret
    refute Redaction.format_error(material) =~ @secret
    refute inspect(material) =~ @secret
  end

  test "variables that redirect another tool's login are rejected without echoing values" do
    for name <- ~w(HOME CLAUDE_CONFIG_DIR USERPROFILE Home userprofile claude_config_dir) do
      opts = opts_with(%{"routes" => %{"bridge" => %{"env" => %{name => @secret}}}})

      assert {:error, {:route_unavailable, message}} =
               Credentials.route_credential("bridge", opts)

      assert message =~ "routes.bridge.env"
      assert message =~ name
      refute message =~ @secret

      assert {:error, {:route_unavailable, ^message}} =
               Credentials.bind_request(RouteOwned.new("bridge", nil), nil, opts)
    end
  end

  test "malformed route entries are rejected with the route named" do
    for entry <- [%{"env" => "x"}, %{"env" => %{"A" => 1}}, "not-a-map"] do
      opts = opts_with(%{"routes" => %{"bridge" => entry}})

      assert {:error, {:route_unavailable, message}} =
               Credentials.route_credential("bridge", opts)

      assert message =~ "routes.bridge.env"
    end
  end

  test "a routes section does not become an API-key provider" do
    opts = opts_with(%{"routes" => %{"bridge" => %{"env" => %{"BRIDGE_TOKEN" => @secret}}}})
    refute Map.has_key?(Credentials.snapshot(opts).provider_sources, "routes")
  end
end
