defmodule Minga.ConformanceRecoveryEvidenceTest do
  # System.cmd opens real OS ports; keep these script checks out of the async pool.
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/check_conformance_recovery", __DIR__)
  @unit_tests Path.join(__DIR__, "conformance_recovery_evidence_test.py")

  test "help is Linux-safe and never requires native tools" do
    assert {output, 0} = System.cmd("python3", [@script, "--help"], stderr_to_stdout: true)
    assert output =~ "--producer-only"
    assert output =~ "--derived-data"
  end

  test "classifies only real named policy failures and preserves replay accounting" do
    assert {output, 0} = System.cmd("python3", [@unit_tests], stderr_to_stdout: true)
    assert output =~ "OK"
  end
end
