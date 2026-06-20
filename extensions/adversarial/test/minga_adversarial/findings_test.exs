defmodule MingaAdversarial.FindingsTest do
  use ExUnit.Case, async: true

  alias MingaAdversarial.Findings

  test "parses a clean JSON array and converts to 0-based lines" do
    json =
      ~s([{"line": 14, "concern": "assumes list non-empty"}, {"line": 1, "concern": "no nil guard"}])

    assert Findings.parse(json) == [
             %{line: 13, concern: "assumes list non-empty"},
             %{line: 0, concern: "no nil guard"}
           ]
  end

  test "extracts the array out of prose and code fences" do
    text = """
    Sure! Here are the issues I found:

    ```json
    [{"line": 3, "concern": "P99 is 340ms, not under 100ms"}]
    ```

    Hope that helps.
    """

    assert Findings.parse(text) == [%{line: 2, concern: "P99 is 340ms, not under 100ms"}]
  end

  test "returns [] for an empty array" do
    assert Findings.parse("[]") == []
  end

  test "returns [] for malformed output and never raises" do
    assert Findings.parse("not json at all") == []
    assert Findings.parse("[{unterminated") == []
    assert Findings.parse("") == []
  end

  test "drops entries with missing or wrong-typed fields" do
    json =
      ~s([{"line": 5, "concern": "kept"}, {"line": "x", "concern": "bad line"}, {"concern": "no line"}, {"line": 9}, {"line": 2, "concern": ""}])

    assert Findings.parse(json) == [%{line: 4, concern: "kept"}]
  end

  test "clamps a 0 or negative line to 0" do
    assert Findings.parse(~s([{"line": 0, "concern": "c"}])) == [%{line: 0, concern: "c"}]
  end
end
