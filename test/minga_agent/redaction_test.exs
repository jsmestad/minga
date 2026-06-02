defmodule MingaAgent.RedactionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.Redaction

  test "redacts secret-key tuples of any arity" do
    redacted = Redaction.redact_term({:API_TOKEN, "plain-secret", :metadata})

    assert redacted == {:API_TOKEN, "[REDACTED]", "[REDACTED]"}
    refute inspect(redacted) =~ "plain-secret"
  end

  test "redacts keyword-list secret values" do
    redacted = Redaction.redact_term(API_TOKEN: "plain-secret", mode: "safe")

    assert redacted[:API_TOKEN] == "[REDACTED]"
    assert redacted[:mode] == "safe"
    refute inspect(redacted) =~ "plain-secret"
  end

  test "redacts assignment-style secrets in strings" do
    message = "failed with API_TOKEN=plain-secret password: hunter2 --token inline-secret"

    redacted = Redaction.redact_string(message)

    refute redacted =~ "plain-secret"
    refute redacted =~ "hunter2"
    refute redacted =~ "inline-secret"
    assert redacted =~ "API_TOKEN=[REDACTED]"
    assert redacted =~ "password: [REDACTED]"
    assert redacted =~ "--token [REDACTED]"
  end

  test "redacts serialized key-value secrets in strings" do
    secret = "plain-secret"

    json = Redaction.redact_string(~s({"token":"#{secret}","mode":"safe"}))
    inspected = Redaction.redact_string(~s(%{"token" => "#{secret}", "mode" => "safe"}))

    refute json =~ secret
    refute inspected =~ secret
    assert json =~ ~s("token":"[REDACTED]")
    assert inspected =~ ~s("token" => "[REDACTED]")
  end

  test "redacts bearer headers and query string tokens" do
    message =
      "Authorization: Bearer ghp_supersecret123 url=https://example.test?access_token=plain-secret&ok=1"

    redacted = Redaction.redact_string(message)

    refute redacted =~ "ghp_supersecret123"
    refute redacted =~ "plain-secret"
    assert redacted =~ "Bearer [REDACTED]"
    assert redacted =~ "access_token=[REDACTED]"
  end

  test "format_error redacts server config env values" do
    secret = "ghp_supersecret123"

    formatted =
      Redaction.format_error(%ServerConfig{
        name: "local-tools",
        command: "node",
        args: ["--api-key", secret],
        env: %{"GITHUB_TOKEN" => secret, "MODE" => "dev"}
      })

    refute formatted =~ secret
    refute formatted =~ "dev"
    assert formatted =~ "GITHUB_TOKEN"
    assert formatted =~ "MODE"
    assert formatted =~ "[REDACTED]"
  end

  test "format_error redacts printable charlist secrets" do
    secret = "plain-secret"

    formatted = Redaction.format_error({:error, ~c"API_TOKEN=#{secret}"})

    refute formatted =~ secret
    assert formatted =~ "API_TOKEN=[REDACTED]"
  end

  test "redact_term redacts nested printable charlist secrets" do
    secret = "plain-secret"

    redacted = Redaction.redact_term(%{"content" => [~c"API_TOKEN=#{secret}"]})

    refute inspect(redacted) =~ secret
    assert inspect(redacted) =~ "API_TOKEN=[REDACTED]"
  end

  test "redacts split argv-style secret values" do
    redacted =
      Redaction.redact_args([
        "--api-key",
        "plain-secret",
        "--client-secret",
        "compound-secret",
        "--mode",
        "safe"
      ])

    assert redacted == [
             "--api-key",
             "[REDACTED]",
             "--client-secret",
             "[REDACTED]",
             "--mode",
             "safe"
           ]
  end

  test "redacts inline compound argv-style secret values" do
    redacted = Redaction.redact_args(["--refresh-token=plain-secret", "--private-key=key-secret"])

    assert redacted == ["--refresh-token=[REDACTED]", "--private-key=[REDACTED]"]
  end
end
