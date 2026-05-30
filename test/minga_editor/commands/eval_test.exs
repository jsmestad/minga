defmodule MingaEditor.Commands.EvalTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Eval
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport

  defp build_state do
    %EditorState{
      port_manager: nil,
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{}
      }
    }
  end

  defp singleton_content do
    Logger.flush()
    Process.sleep(10)

    case Minga.Log.MessagesBuffer.pid() do
      nil -> ""
      pid -> BufferProcess.content(pid)
    end
  end

  describe "simple expression evaluation" do
    test "evaluates arithmetic and shows result on status line" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "1 + 1"})
      assert result.shell_state.status_msg == "2"
    end

    test "evaluates string expressions" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, ~s("hello" <> " world")})
      assert result.shell_state.status_msg == ~s("hello world")
    end

    test "evaluates list expressions" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "Enum.map([1,2,3], & &1 * 2)"})
      assert result.shell_state.status_msg == "[2, 4, 6]"
    end
  end

  describe "editor binding" do
    test "editor binding contains the current process PID" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "editor"})
      assert result.shell_state.status_msg == inspect(self())
    end
  end

  describe "error handling" do
    @tag capture_log: true
    test "syntax error returns formatted error on status line" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "1 +"})
      assert result.shell_state.status_msg =~ "**"
    end

    test "runtime error returns formatted error without crashing" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "1 / 0"})
      assert result.shell_state.status_msg =~ "ArithmeticError"
    end

    @tag capture_log: true
    test "undefined variable returns error" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "undefined_var"})

      assert result.shell_state.status_msg =~ "undefined variable"
    end

    test "throw is caught and displayed" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "throw(:oops)"})
      assert result.shell_state.status_msg =~ "**"
    end
  end

  describe "timeout handling" do
    test "long-running eval times out gracefully" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, ":timer.sleep(10_000)"}, timeout: 100)
      assert result.shell_state.status_msg == "Eval timed out (0s)"
    end
  end

  describe "messages buffer logging" do
    test "result is logged to messages buffer" do
      state = build_state()
      Eval.execute(state, {:eval_expression, "42"})

      content = singleton_content()
      assert content =~ "Eval: 42"
      assert content =~ "=> 42"
    end

    test "error is logged to messages buffer" do
      state = build_state()
      Eval.execute(state, {:eval_expression, "1 / 0"})

      content = singleton_content()
      assert content =~ "Eval error: 1 / 0"
      assert content =~ "ArithmeticError"
    end

    test "works without messages buffer singleton" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "1 + 1"})
      assert result.shell_state.status_msg == "2"
    end
  end
end
