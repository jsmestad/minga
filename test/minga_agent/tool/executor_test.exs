defmodule MingaAgent.Tool.ExecutorTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tool.Executor
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  setup do
    table = :"executor_test_#{:erlang.unique_integer([:positive])}"

    :ets.new(table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    {:ok, table: table}
  end

  defp register_tool(table, name, opts) do
    callback = Keyword.get(opts, :callback, fn _args -> {:ok, "success"} end)
    approval = Keyword.get(opts, :approval_level, :auto)

    spec =
      Spec.new!(
        name: name,
        description: "Test tool: #{name}",
        parameter_schema: %{},
        callback: callback,
        approval_level: approval
      )

    Registry.register(table, spec)
    spec
  end

  describe "execute/3" do
    test "executes auto-approved tool and returns result", %{table: table} do
      register_tool(table, "echo", callback: fn args -> {:ok, args["msg"]} end)
      assert {:ok, "hello"} = Executor.execute("echo", %{"msg" => "hello"}, table)
    end

    test "returns error for unknown tool", %{table: table} do
      assert {:error, {:tool_not_found, "missing"}} =
               Executor.execute("missing", %{}, table)
    end

    test "returns needs_approval for :ask tools", %{table: table} do
      register_tool(table, "dangerous", approval_level: :ask)

      assert {:needs_approval, spec, args} =
               Executor.execute("dangerous", %{"x" => 1}, table)

      assert spec.name == "dangerous"
      assert args == %{"x" => 1}
    end

    test "returns error for :deny tools", %{table: table} do
      register_tool(table, "blocked", approval_level: :deny)

      assert {:error, {:tool_denied, "blocked"}} =
               Executor.execute("blocked", %{}, table)
    end

    test "normalizes bare values to {:ok, value}", %{table: table} do
      register_tool(table, "bare", callback: fn _args -> "just a string" end)
      assert {:ok, "just a string"} = Executor.execute("bare", %{}, table)
    end

    test "normalizes nil to {:error, :no_result}", %{table: table} do
      register_tool(table, "nil_tool", callback: fn _args -> nil end)
      assert {:error, :no_result} = Executor.execute("nil_tool", %{}, table)
    end

    test "catches raised exceptions", %{table: table} do
      register_tool(table, "crasher", callback: fn _args -> raise "boom" end)
      assert {:error, {:raised, "boom"}} = Executor.execute("crasher", %{}, table)
    end

    test "catches thrown values", %{table: table} do
      register_tool(table, "thrower", callback: fn _args -> throw(:oops) end)
      assert {:error, {:crashed, {:throw, :oops}}} = Executor.execute("thrower", %{}, table)
    end

    test "passes through {:error, reason} from callback", %{table: table} do
      register_tool(table, "failing", callback: fn _args -> {:error, :not_found} end)
      assert {:error, :not_found} = Executor.execute("failing", %{}, table)
    end
  end

  describe "execute_approved/2" do
    test "skips approval check and runs callback directly", %{table: table} do
      spec =
        register_tool(table, "approved_tool",
          approval_level: :ask,
          callback: fn _args -> {:ok, "ran"} end
        )

      assert {:ok, "ran"} = Executor.execute_approved(spec, %{})
    end

    test "works even for :deny tools when explicitly approved", %{table: table} do
      spec =
        register_tool(table, "deny_override",
          approval_level: :deny,
          callback: fn _args -> {:ok, "forced"} end
        )

      assert {:ok, "forced"} = Executor.execute_approved(spec, %{})
    end
  end
end
