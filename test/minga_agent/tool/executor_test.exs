defmodule MingaAgent.Tool.ExecutorTest do
  use ExUnit.Case, async: false

  alias Minga.Config.Advice
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.Result
  alias MingaAgent.Tool.BundledSources
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Executor
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  setup do
    Advice.reset()
    on_exit(&Advice.reset/0)

    table = :"executor_test_#{:erlang.unique_integer([:positive])}"

    :ets.new(table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    {:ok, table: table}
  end

  defp register_tool(table, name, opts) do
    callback = Keyword.get(opts, :callback, fn _args -> {:ok, "success"} end)
    approval = Keyword.get(opts, :approval_level, :auto)
    source = Keyword.get(opts, :source, source_for_test_tool(name))

    spec =
      Spec.new!(
        source: source,
        name: name,
        description: "Test tool: #{name}",
        parameter_schema: %{},
        callback: callback,
        approval_level: approval
      )

    assert :ok = Registry.register(table, spec)
    spec
  end

  defp source_for_test_tool(name) do
    source_for_test_tool(
      name in MingaAgent.Tools.builtin_names(),
      BundledSources.reserved_source_for(name)
    )
  end

  defp source_for_test_tool(true, _reserved), do: :builtin
  defp source_for_test_tool(false, {:ok, source}), do: source
  defp source_for_test_tool(false, :error), do: :config

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

    test "runs matching PreToolUse hook before tool callback", %{table: table} do
      test_pid = self()

      register_tool(table, "echo",
        callback: fn args ->
          send(test_pid, {:callback_ran, args})
          {:ok, "success"}
        end
      )

      hook = %Hook{event: :pre_tool_use, tool_pattern: "echo", command: "policy"}
      config = %AgentConfig{agent_hooks: [hook]}

      runner = fn ^hook, payload ->
        send(test_pid, {:hook_ran, payload.tool_name, payload.arguments})
        Result.allow(hook)
      end

      assert {:ok, "success"} =
               Executor.execute("echo", %{"msg" => "hello"}, table, :exec,
                 config: config,
                 hook_runner: runner
               )

      assert_received {:hook_ran, "echo", %{"msg" => "hello"}}
      assert_received {:callback_ran, %{"msg" => "hello"}}
    end

    test "veto prevents tool callback", %{table: table} do
      test_pid = self()

      register_tool(table, "shell",
        callback: fn _args ->
          send(test_pid, :callback_ran)
          {:ok, "should not run"}
        end
      )

      hook = %Hook{event: :pre_tool_use, tool_pattern: "shell", command: "policy"}
      config = %AgentConfig{agent_hooks: [hook]}
      runner = fn ^hook, _payload -> Result.veto(hook, "blocked by policy", {:exit, 9}) end

      assert {:error, {:hook_veto, message}} =
               Executor.execute("shell", %{"command" => "date"}, table, :exec,
                 config: config,
                 hook_runner: runner
               )

      assert message =~ "blocked by policy"
      refute_received :callback_ran
    end
  end

  describe "context-bound execution" do
    test "context-free built-in specs execute without ToolContext", %{table: table} do
      spec = Enum.find(MingaAgent.Tools.builtin_specs(), &(&1.name == "describe_runtime"))
      assert spec.context_requirements == []
      assert :ok = Registry.register(table, spec)

      assert {:ok, result} = Executor.execute("describe_runtime", %{}, table)
      assert result =~ "Minga Runtime"
    end

    test "mutating context-bound tools refuse without ToolContext before build runs", %{
      table: table
    } do
      parent = self()

      spec =
        Spec.new!(
          source: :config,
          name: "context_write",
          description: "Context write",
          parameter_schema: %{},
          category: :filesystem,
          approval_level: :auto,
          capabilities: [:mutate_project],
          context_requirements: [:tool_context],
          build: fn context ->
            send(parent, {:built, context})
            fn _args -> {:ok, "wrote"} end
          end
        )

      assert :ok = Registry.register(table, spec)

      assert {:error, {:missing_tool_context, "context_write", [:tool_context]}} =
               Executor.execute("context_write", %{}, table)

      refute_receive {:built, _}
    end

    test "approved mutating tools still require ToolContext", %{table: table} do
      spec =
        Spec.new!(
          source: :config,
          name: "approved_context_write",
          description: "Context write",
          parameter_schema: %{},
          category: :filesystem,
          approval_level: :ask,
          capabilities: [:mutate_project],
          context_requirements: [:tool_context],
          build: fn _context -> fn _args -> {:ok, "wrote"} end end
        )

      assert :ok = Registry.register(table, spec)

      assert {:error, {:missing_tool_context, "approved_context_write", [:tool_context]}} =
               Executor.execute_approved(spec, %{})
    end

    test "context-bound build receives ToolContext and executes with args", %{table: table} do
      parent = self()

      spec =
        Spec.new!(
          source: :config,
          name: "context_echo",
          description: "Context echo",
          parameter_schema: %{},
          context_requirements: [:tool_context],
          build: fn context ->
            send(parent, {:built, context})
            fn args -> {:ok, {context.project_root, args}} end
          end
        )

      assert :ok = Registry.register(table, spec)

      context =
        Context.new(
          project_root: "/tmp/context-root",
          router_context: MingaAgent.ToolRouter.context(nil, nil)
        )

      assert {:ok, {"/tmp/context-root", %{"x" => 1}}} =
               Executor.execute("context_echo", %{"x" => 1}, table, :exec, tool_context: context)

      assert_received {:built, ^context}
    end
  end

  describe "plan mode" do
    test "refuses destructive tools before the callback runs", %{table: table} do
      parent = self()

      register_tool(table, "write_file",
        callback: fn args ->
          send(parent, {:called, "write_file", args})
          {:ok, "wrote"}
        end
      )

      assert {:error, {:plan_mode_refused, message}} =
               Executor.execute("write_file", %{"path" => "x", "content" => "new"}, table, :plan)

      assert message =~ "Plan mode"
      assert message =~ "write_file"
      assert message =~ "/exec"
      refute_receive {:called, "write_file", _}, 20
    end

    test "allows read-only and search tools", %{table: table} do
      parent = self()

      register_tool(table, "read_file",
        callback: fn _args ->
          send(parent, {:called, "read_file"})
          {:ok, "content"}
        end
      )

      register_tool(table, "grep",
        callback: fn _args ->
          send(parent, {:called, "grep"})
          {:ok, "matches"}
        end
      )

      assert {:ok, "content"} = Executor.execute("read_file", %{"path" => "x"}, table, :plan)
      assert {:ok, "matches"} = Executor.execute("grep", %{"pattern" => "x"}, table, :plan)
      assert_receive {:called, "read_file"}
      assert_receive {:called, "grep"}
    end

    test "refuses code actions only when applying changes", %{table: table} do
      parent = self()

      register_tool(table, "code_actions",
        callback: fn args ->
          send(parent, {:called, args})
          {:ok, "actions"}
        end
      )

      assert {:ok, "actions"} =
               Executor.execute("code_actions", %{"path" => "x.ex"}, table, :plan)

      assert_receive {:called, %{"path" => "x.ex"}}

      assert {:error, {:plan_mode_refused, message}} =
               Executor.execute(
                 "code_actions",
                 %{"path" => "x.ex", "apply" => "Organize imports"},
                 table,
                 :plan
               )

      assert message =~ "Plan mode"
      refute_receive {:called, %{"apply" => "Organize imports"}}, 20
    end

    test "refuses already-approved destructive tools before callback runs", %{table: table} do
      parent = self()

      spec =
        register_tool(table, "git_commit",
          approval_level: :ask,
          callback: fn _args ->
            send(parent, :called)
            {:ok, "committed"}
          end
        )

      assert {:error, {:plan_mode_refused, message}} =
               Executor.execute_approved(spec, %{"message" => "test"}, :plan)

      assert message =~ "git_commit"
      refute_receive :called, 20
    end
  end

  describe "advised execution" do
    test "before and after advice preserve normalized results and authorized arguments", %{
      table: table
    } do
      parent = self()

      register_tool(table, "advised_arguments",
        callback: fn args ->
          send(parent, {:tool_arguments, args})
          {:ok, args["message"]}
        end
      )

      Advice.register(:before, :advised_arguments, fn state ->
        Map.put(state, "message", "changed by advice")
      end)

      Advice.register(:after, :advised_arguments, fn state ->
        Map.put(state, :after_ran, true)
      end)

      assert {:ok, "authorized"} =
               Executor.execute("advised_arguments", %{"message" => "authorized"}, table)

      assert_received {:tool_arguments, %{"message" => "authorized"}}

      register_tool(table, "advised_error", callback: fn _args -> {:error, :tool_failure} end)
      Advice.register(:after, :advised_error, fn state -> Map.put(state, :observed, true) end)

      assert {:error, :tool_failure} = Executor.execute("advised_error", %{}, table)
    end

    test "nested advised execution from after advice cannot replace the outer result", %{
      table: table
    } do
      parent = self()
      register_tool(table, "nested_outer", callback: fn _args -> {:ok, "outer"} end)
      register_tool(table, "nested_inner", callback: fn _args -> {:ok, "inner"} end)

      Advice.register(:before, :nested_inner, fn state -> state end)

      Advice.register(:after, :nested_outer, fn state ->
        send(parent, {:nested_result, Executor.execute("nested_inner", %{}, table)})
        state
      end)

      assert {:ok, "outer"} = Executor.execute("nested_outer", %{}, table)
      assert_received {:nested_result, {:ok, "inner"}}
    end

    test "around advice can replace or skip a tool result without ambient state", %{table: table} do
      parent = self()

      register_tool(table, "replacement_tool",
        callback: fn _args ->
          send(parent, :replacement_core_ran)
          {:ok, "core"}
        end
      )

      Advice.register(:around, :replacement_tool, fn _inner, state ->
        {:returned, state, {:ok, "replacement"}}
      end)

      assert {:ok, "replacement"} = Executor.execute("replacement_tool", %{}, table)
      refute_received :replacement_core_ran

      register_tool(table, "conditional_skip", callback: fn _args -> {:ok, "fresh"} end)

      Advice.register(:around, :conditional_skip, fn inner, state ->
        if state["skip"], do: state, else: inner.(state)
      end)

      assert {:error, :no_result} = Executor.execute("conditional_skip", %{"skip" => true}, table)
      assert {:ok, "fresh"} = Executor.execute("conditional_skip", %{"skip" => false}, table)
    end

    test "after advice failure retains the tool result", %{table: table} do
      register_tool(table, "failing_after", callback: fn _args -> {:error, :tool_failure} end)
      Advice.register(:after, :failing_after, fn _state -> raise "advice failure" end)

      assert {:error, :tool_failure} = Executor.execute("failing_after", %{}, table)
    end

    test "around failure after running the tool skips without retrying", %{table: table} do
      parent = self()
      calls = :counters.new(1, [:atomics])

      register_tool(table, "failing_around",
        callback: fn _args ->
          :counters.add(calls, 1, 1)
          {:ok, "core"}
        end
      )

      Advice.register(:around, :failing_around, fn inner, state ->
        send(parent, {:inner_outcome, inner.(state)})
        raise "after core"
      end)

      assert {:error, :no_result} = Executor.execute("failing_around", %{}, table)
      assert :counters.get(calls, 1) == 1
      assert_received {:inner_outcome, {:returned, %{}, {:ok, "core"}}}
    end

    test "advised tool raises and exits remain tool failures and do not leak", %{table: table} do
      calls = :counters.new(1, [:atomics])

      register_tool(table, "advised_flaky",
        callback: fn _args ->
          :counters.add(calls, 1, 1)

          case :counters.get(calls, 1) do
            1 -> raise "boom"
            _ -> {:ok, "recovered"}
          end
        end
      )

      register_tool(table, "advised_exit", callback: fn _args -> exit(:boom) end)
      Advice.register(:before, :advised_flaky, fn state -> state end)
      Advice.register(:before, :advised_exit, fn state -> state end)

      assert {:error, {:raised, "boom"}} = Executor.execute("advised_flaky", %{}, table)
      assert {:ok, "recovered"} = Executor.execute("advised_flaky", %{}, table)
      assert {:error, {:crashed, {:exit, :boom}}} = Executor.execute("advised_exit", %{}, table)
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
