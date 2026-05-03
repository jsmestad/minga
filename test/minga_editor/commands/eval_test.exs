defmodule MingaEditor.Commands.EvalTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.Commands.Eval
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport

  # ── Test helpers ──────────────────────────────────────────────────────────────

  defp start_messages_buffer do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {BufferServer,
         content: "", buffer_name: "*Messages*", read_only: true, unlisted: true, persistent: true}
      )

    pid
  end

  defp build_state(messages_buf \\ nil) do
    %EditorState{
      port_manager: nil,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{messages: messages_buf}
      }
    }
  end

  defp messages_content(buf) do
    BufferServer.content(buf)
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

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

      # Note: `Code.eval_string("undefined_var")` writes a compiler diagnostic
      # to stderr. We used to wrap this in `ExUnit.CaptureIO.capture_io(:stderr,
      # ...)` to keep test output clean, but that races with other async tests
      # over the global :standard_error process and crashes ExUnit.CaptureServer
      # on CI (see PR #1442 for the failure trace). The diagnostic line is
      # tolerable; correctness is what we care about here.
      result = Eval.execute(state, {:eval_expression, "undefined_var"})

      assert result.shell_state.status_msg =~ "**"
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
      messages_buf = start_messages_buffer()
      state = build_state(messages_buf)
      Eval.execute(state, {:eval_expression, "42"})

      content = messages_content(messages_buf)
      assert content =~ "Eval: 42"
      assert content =~ "=> 42"
    end

    test "error is logged to messages buffer" do
      messages_buf = start_messages_buffer()
      state = build_state(messages_buf)
      Eval.execute(state, {:eval_expression, "1 / 0"})

      content = messages_content(messages_buf)
      assert content =~ "Eval error: 1 / 0"
      assert content =~ "ArithmeticError"
    end

    test "works without messages buffer (nil)" do
      state = build_state(nil)
      result = Eval.execute(state, {:eval_expression, "1 + 1"})
      assert result.shell_state.status_msg == "2"
    end
  end
end
