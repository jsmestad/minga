defmodule Minga.Agent.View.HelpTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.View.Help

  describe "chat_bindings/0" do
    test "returns non-empty list of groups" do
      groups = Help.chat_bindings()
      assert [_ | _] = groups
    end

    test "each group has a label and bindings list" do
      for {label, bindings} <- Help.chat_bindings() do
        assert is_binary(label)
        assert is_list(bindings)

        for {key, desc} <- bindings do
          assert is_binary(key)
          assert is_binary(desc)
        end
      end
    end

    test "includes navigation and copy categories" do
      labels = Enum.map(Help.chat_bindings(), fn {label, _} -> label end)
      assert "Navigation" in labels
      assert "Copy" in labels
      assert "Session" in labels
    end
  end

  describe "viewer_bindings/0" do
    test "returns non-empty list of groups" do
      groups = Help.viewer_bindings()
      assert [_ | _] = groups
    end

    test "includes navigation category" do
      labels = Enum.map(Help.viewer_bindings(), fn {label, _} -> label end)
      assert "Navigation" in labels
    end

    test "has fewer groups than chat bindings" do
      assert length(Help.viewer_bindings()) < length(Help.chat_bindings())
    end
  end
end
