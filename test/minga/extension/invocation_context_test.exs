defmodule Minga.Extension.InvocationContextTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.InvocationContext
  alias MingaEditor.UI.Picker.Source

  test "installs authoritative attribution independently of callback module nesting" do
    source = {:extension, :authoritative_owner}

    assert InvocationContext.current_source() == :none

    assert InvocationContext.with_source(source, fn ->
             assert InvocationContext.current_source() == {:ok, source}
             assert Source.source_identity(Unrelated.Namespace.Picker) == source
             :returned
           end) == :returned

    assert InvocationContext.current_source() == :none
  end

  test "nested and raising invocations restore the prior source" do
    outer = {:extension, :outer}
    inner = {:extension, :inner}

    assert_raise RuntimeError, "outer callback failed", fn ->
      InvocationContext.with_source(outer, fn ->
        assert_raise RuntimeError, "inner callback failed", fn ->
          InvocationContext.with_source(inner, fn ->
            assert InvocationContext.current_source() == {:ok, inner}
            raise "inner callback failed"
          end)
        end

        assert InvocationContext.current_source() == {:ok, outer}
        raise "outer callback failed"
      end)
    end

    assert InvocationContext.current_source() == :none
  end
end
