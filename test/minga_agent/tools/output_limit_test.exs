defmodule MingaAgent.Tools.OutputLimitTest do
  # Spawns OS processes through Port command collection.
  use ExUnit.Case, async: false

  @moduletag :heavy

  alias MingaAgent.Tools.OutputLimit
  alias MingaAgent.Tools.OutputLimit.Result

  describe "collect_command/3" do
    test "keeps an incomplete UTF-8 prefix valid when the cap splits a codepoint" do
      assert %Result{
               output: output,
               status: :terminated,
               capture: {:incomplete, :capture_byte_limit}
             } =
               OutputLimit.collect_command(
                 "/bin/sh",
                 ["-c", "printf '\\342'; printf '\\202\\254'"],
                 max_bytes: 1,
                 timeout_ms: 1_000
               )

      assert String.valid?(output)
    end

    test "terminates the producer and reports an incomplete capture at the byte allowance" do
      assert %Result{
               output: "abc",
               status: :terminated,
               capture: {:incomplete, :capture_byte_limit}
             } =
               OutputLimit.collect_command("/bin/sh", ["-c", "printf 'abcdef'; exit 42"],
                 max_bytes: 3,
                 timeout_ms: 1_000
               )
    end

    test "returns timeout and incomplete status for a producer that does not exit" do
      assert %Result{
               output: output,
               status: :timeout,
               capture: {:incomplete, :timeout}
             } =
               OutputLimit.collect_command("/bin/sh", ["-c", "exec sleep 60"],
                 max_bytes: 16,
                 timeout_ms: 20
               )

      assert output == ""
    end
  end
end
