defmodule MingaAgent.Hooks.ModuleRunnerTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.ModuleRunner
  alias MingaAgent.Hooks.Result

  defmodule AllowPolicy do
    @spec check(map()) :: :allow
    def check(_payload), do: :allow
  end

  defmodule VetoPolicy do
    @spec check(map()) :: {:veto, String.t()}
    def check(_payload), do: {:veto, "blocked by policy"}
  end

  defmodule SlowPolicy do
    @spec check(map()) :: :allow
    def check(_payload) do
      Process.sleep(5_000)
      :allow
    end
  end

  defmodule CrashPolicy do
    @spec check(map()) :: no_return()
    def check(_payload), do: raise("boom")
  end

  defmodule BadReturnPolicy do
    @spec check(map()) :: :bad
    def check(_payload), do: :bad
  end

  test "allows when module returns :allow" do
    hook = module_hook(AllowPolicy, :check)
    result = ModuleRunner.run(hook, %{"event" => "PreToolUse", "tool_name" => "shell"})

    assert %Result{status: :allow, hook: ^hook} = result
  end

  test "vetoes when module returns {:veto, reason}" do
    hook = module_hook(VetoPolicy, :check)
    result = ModuleRunner.run(hook, %{"event" => "PreToolUse", "tool_name" => "shell"})

    assert %Result{status: :veto, stderr: "blocked by policy"} = result
  end

  test "vetoes on timeout" do
    hook = module_hook(SlowPolicy, :check, 50)
    result = ModuleRunner.run(hook, %{"event" => "PreToolUse"})

    assert %Result{status: :veto, reason: :timeout} = result
    assert result.stderr =~ "timed out"
  end

  test "vetoes when module raises" do
    hook = module_hook(CrashPolicy, :check)
    result = ModuleRunner.run(hook, %{"event" => "PreToolUse"})

    assert %Result{status: :veto} = result
    assert result.stderr =~ "boom"
  end

  test "vetoes on unexpected return value" do
    hook = module_hook(BadReturnPolicy, :check)
    result = ModuleRunner.run(hook, %{"event" => "PreToolUse"})

    assert %Result{status: :veto} = result
    assert result.stderr =~ "unexpected value"
  end

  test "dispatcher routes module hooks to ModuleRunner" do
    hook = module_hook(AllowPolicy, :check)
    payload = %{"event" => "PreToolUse", "tool_name" => "shell", "tool_call_id" => "tc_mod"}

    assert :ok =
             MingaAgent.Hooks.Dispatcher.dispatch(:pre_tool_use, [hook], payload,
               veto_capable: true
             )
  end

  test "normalization accepts module hook config" do
    assert {:ok, %Hook{type: :module, module: AllowPolicy, function: :check}} =
             Hook.normalize(%{
               event: "PreToolUse",
               tool: "shell",
               type: :module,
               module: AllowPolicy,
               function: :check
             })
  end

  test "normalization auto-detects module type" do
    assert {:ok, %Hook{type: :module}} =
             Hook.normalize(%{
               event: "PreToolUse",
               tool: "*",
               module: AllowPolicy,
               function: :check
             })
  end

  test "normalization rejects module hook without function" do
    assert {:error, "module hook requires :function"} =
             Hook.normalize(%{event: "PreToolUse", tool: "*", type: :module, module: AllowPolicy})
  end

  test "normalization rejects module hook without module" do
    assert {:error, "module hook requires :module"} =
             Hook.normalize(%{event: "PreToolUse", tool: "*", type: :module, function: :check})
  end

  defp module_hook(mod, fun, timeout_ms \\ 30_000) do
    %Hook{
      event: :pre_tool_use,
      type: :module,
      tool_pattern: "*",
      module: mod,
      function: fun,
      timeout_ms: timeout_ms
    }
  end
end
