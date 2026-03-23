defmodule Minga.Buffer.EditSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.EditSource

  describe "constructors" do
    test "user/0 returns :user" do
      assert EditSource.user() == :user
    end

    test "agent/2 returns tagged tuple with validated args" do
      result = EditSource.agent(self(), "call_123")
      assert {:agent, pid, "call_123"} = result
      assert pid == self()
    end

    test "lsp/1 returns tagged tuple with server name" do
      assert EditSource.lsp(:elixir_ls) == {:lsp, :elixir_ls}
    end

    test "formatter/0 returns :formatter" do
      assert EditSource.formatter() == :formatter
    end

    test "unknown/0 returns :unknown" do
      assert EditSource.unknown() == :unknown
    end

    test "agent/2 rejects non-pid session_id" do
      assert_raise FunctionClauseError, fn -> EditSource.agent("not-a-pid", "call") end
    end

    test "agent/2 rejects non-binary tool_call_id" do
      assert_raise FunctionClauseError, fn -> EditSource.agent(self(), :not_binary) end
    end

    test "lsp/1 rejects non-atom server_name" do
      assert_raise FunctionClauseError, fn -> EditSource.lsp("elixir_ls") end
    end
  end

  describe "to_undo_source/1" do
    test "maps :user to :user" do
      assert EditSource.to_undo_source(EditSource.user()) == :user
    end

    test "maps {:agent, pid, tool_call_id} to :agent" do
      assert EditSource.to_undo_source(EditSource.agent(self(), "call_123")) == :agent
    end

    test "maps {:lsp, server_name} to :lsp" do
      assert EditSource.to_undo_source(EditSource.lsp(:elixir_ls)) == :lsp
    end

    test "maps :formatter to :lsp" do
      assert EditSource.to_undo_source(EditSource.formatter()) == :lsp
    end

    test "maps :unknown to :user" do
      assert EditSource.to_undo_source(EditSource.unknown()) == :user
    end
  end

  describe "from_undo_source/1" do
    test "maps :user to :user" do
      assert EditSource.from_undo_source(:user) == EditSource.user()
    end

    test "maps :agent to {:agent, self(), \"unknown\"}" do
      result = EditSource.from_undo_source(:agent)
      assert {:agent, pid, "unknown"} = result
      assert is_pid(pid)
    end

    test "maps :lsp to {:lsp, :unknown}" do
      assert EditSource.from_undo_source(:lsp) == EditSource.lsp(:unknown)
    end

    test "maps :recovery to :unknown" do
      assert EditSource.from_undo_source(:recovery) == EditSource.unknown()
    end
  end
end
