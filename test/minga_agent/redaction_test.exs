defmodule MingaAgent.RedactionTest do
  use ExUnit.Case, async: true

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
