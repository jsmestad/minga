defmodule MingaAgent.Providers.Native.ToolResultBoundTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Providers.Native.ToolResultBound

  test "text within the bound, or with no bound, is unchanged" do
    text = String.duplicate("line\n", 100)
    assert ToolResultBound.limit(text, :unbounded) == text
    assert ToolResultBound.limit(text, {:bytes, byte_size(text)}) == text
  end

  test "an oversized result keeps whole leading lines and states both sizes" do
    text = Enum.map_join(1..1_000, "\n", &"line #{&1}")
    bounded = ToolResultBound.limit(text, {:bytes, 2_048})

    [kept, marker] = String.split(bounded, "\n[Minga truncated", parts: 2)
    assert byte_size(kept) <= 2_048
    assert String.starts_with?(text, kept <> "\n")
    assert marker =~ "this result from #{byte_size(text)} to #{byte_size(kept)} bytes"
    assert marker =~ "read_file with offset and limit"
  end

  test "a cut never splits a multi-byte character" do
    text = String.duplicate("é", 2_000)
    bounded = ToolResultBound.limit(text, {:bytes, 1_001})

    assert String.valid?(bounded)
    assert String.starts_with?(bounded, String.duplicate("é", 500) <> "\n[Minga truncated")
  end
end
