defmodule Minga.Buffer.EditSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.EditSource

  describe "to_undo_source/1" do
    test "maps :user to :user" do
      assert EditSource.to_undo_source(:user) == :user
    end

    test "maps {:agent, pid, tool_call_id} to :agent" do
      assert EditSource.to_undo_source({:agent, self(), "call_123"}) == :agent
    end

    test "maps {:lsp, server_name} to :lsp" do
      assert EditSource.to_undo_source({:lsp, :elixir_ls}) == :lsp
    end

    test "maps :formatter to :lsp" do
      assert EditSource.to_undo_source(:formatter) == :lsp
    end

    test "maps :unknown to :user" do
      assert EditSource.to_undo_source(:unknown) == :user
    end
  end

  describe "from_undo_source/1" do
    test "maps :user to :user" do
      assert EditSource.from_undo_source(:user) == :user
    end

    test "maps :agent to {:agent, self(), \"unknown\"}" do
      result = EditSource.from_undo_source(:agent)
      assert {:agent, pid, "unknown"} = result
      assert is_pid(pid)
    end

    test "maps :lsp to {:lsp, :unknown}" do
      assert EditSource.from_undo_source(:lsp) == {:lsp, :unknown}
    end

    test "maps :recovery to :unknown" do
      assert EditSource.from_undo_source(:recovery) == :unknown
    end
  end
end
