defmodule MingaAgent.Tools.OutputLimitTest do
  # Spawns OS processes through Port command collection.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.OutputLimit

  describe "collect_command/3" do
    test "keeps truncated output valid when the cap splits a UTF-8 character across chunks" do
      {output, status, truncated?} =
        OutputLimit.collect_command(
          "/bin/sh",
          ["-c", "printf '\\342'; sleep 0.05; printf '\\202\\254'"],
          max_bytes: 1,
          timeout_ms: 1_000
        )

      assert status == 0
      assert truncated?
      assert String.valid?(output)
    end

    test "keeps the real exit status after output is capped" do
      {output, status, truncated?} =
        OutputLimit.collect_command("/bin/sh", ["-c", "printf 'abcdef'; exit 42"],
          max_bytes: 3,
          timeout_ms: 1_000
        )

      assert output == "abc"
      assert status == 42
      assert truncated?
    end

    test "returns timeout instead of success for capped commands that keep running" do
      {output, status, truncated?} =
        OutputLimit.collect_command("/bin/sh", ["-c", "yes x 2>/dev/null"],
          max_bytes: 16,
          timeout_ms: 100
        )

      assert status == :timeout
      assert truncated?
      assert String.valid?(output)
    end
  end
end
