defmodule MingaEditor.Commands.EvalTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Events
  alias Minga.Events.LogMessageEvent
  alias MingaEditor.Commands.Eval
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers

  defp build_state do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %MingaEditor.Session.State{buffers: %Buffers{}}
    }
  end

  defp assert_eval_message(message) do
    direct = "[editor/info] " <> message
    logger = "[info] " <> message
    direct_size = byte_size(direct)
    logger_size = byte_size(logger)

    assert_receive {:minga_event, :log_message, %LogMessageEvent{text: text, level: :info}}
                   when binary_part(text, 0, logger_size) == logger or
                          binary_part(text, 0, direct_size) == direct,
                   1_000

    text
  end

  describe "simple expression evaluation" do
    test "evaluates arithmetic and shows result on status line" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "1 + 1"})
      assert result.shell_runtime.state.notice.message == "2"
    end

    test "evaluates string expressions" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, ~s("hello" <> " world")})
      assert result.shell_runtime.state.notice.message == ~s("hello world")
    end

    test "evaluates list expressions" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "Enum.map([1,2,3], & &1 * 2)"})
      assert result.shell_runtime.state.notice.message == "[2, 4, 6]"
    end
  end

  describe "editor binding" do
    test "editor binding contains the current process PID" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "editor"})
      assert result.shell_runtime.state.notice.message == inspect(self())
    end
  end

  describe "error handling" do
    @tag capture_log: true
    test "syntax error returns formatted error on status line" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "1 +"})
      assert result.shell_runtime.state.notice.message =~ "**"
    end

    test "runtime error returns formatted error without crashing" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "1 / 0"})
      assert result.shell_runtime.state.notice.message =~ "ArithmeticError"
    end

    @tag capture_log: true
    test "undefined variable returns error" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "undefined_var"})

      assert result.shell_runtime.state.notice.message =~ "undefined variable"
    end

    test "throw is caught and displayed" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "throw(:oops)"})
      assert result.shell_runtime.state.notice.message =~ "**"
    end
  end

  describe "timeout handling" do
    test "long-running eval times out gracefully" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, ":timer.sleep(10_000)"}, timeout: 100)
      assert result.shell_runtime.state.notice.message == "Eval timed out (0s)"
    end
  end

  describe "messages buffer logging" do
    test "publishes the evaluated expression and result to Messages" do
      :ok = Events.subscribe(:log_message)
      Eval.execute(build_state(), {:eval_expression, "40 + 2"})

      assert_eval_message("Eval: 40 + 2\n  => 42")
    end

    test "publishes the evaluated expression and error to Messages" do
      :ok = Events.subscribe(:log_message)
      Eval.execute(build_state(), {:eval_expression, "7 / 0"})

      assert assert_eval_message("Eval error: 7 / 0\n") =~ "ArithmeticError"
    end

    test "works without messages buffer singleton" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "1 + 1"})
      assert result.shell_runtime.state.notice.message == "2"
    end
  end
end
