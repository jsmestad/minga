defmodule Minga.Scripts.ReleaseERTSProducerTest do
  # System.cmd opens real OS processes for the Python behavior suite.
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "rejects corrupt sources, unsafe runtime inputs and failed source builds" do
    script = Path.join(__DIR__, "release_erts_producer_test.py")
    {output, status} = System.cmd("python3", [script], stderr_to_stdout: true)
    assert status == 0, output
  end
end
