defmodule Minga.Editor.Commands.EvalTest do
  @moduledoc false
  # async: false because capture_io(:stderr) replaces the global :standard_error
  # process, which breaks concurrent tests that compile code (e.g., extension tests).
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Eval
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState

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
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      vim: VimState.new(),
      buffers: %Buffers{messages: messages_buf}
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
      assert result.status_msg == "2"
    end

    test "evaluates string expressions" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, ~s("hello" <> " world")})
      assert result.status_msg == ~s("hello world")
    end

    test "evaluates list expressions" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "Enum.map([1,2,3], & &1 * 2)"})
      assert result.status_msg == "[2, 4, 6]"
    end
  end

  describe "editor binding" do
    test "editor binding contains the current process PID" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "editor"})
      assert result.status_msg == inspect(self())
    end
  end

  describe "error handling" do
    test "syntax error returns formatted error on status line" do
      state = build_state()

      result =
        capture_io(:stderr, fn ->
          send(self(), {:result, Eval.execute(state, {:eval_expression, "1 +"})})
        end)
        |> then(fn _io ->
          receive do
            {:result, r} -> r
          end
        end)

      assert result.status_msg =~ "**"
    end

    test "runtime error returns formatted error without crashing" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "1 / 0"})
      assert result.status_msg =~ "ArithmeticError"
    end

    test "undefined variable returns error" do
      state = build_state()

      result =
        capture_io(:stderr, fn ->
          send(self(), {:result, Eval.execute(state, {:eval_expression, "undefined_var"})})
        end)
        |> then(fn _io ->
          receive do
            {:result, r} -> r
          end
        end)

      assert result.status_msg =~ "**"
    end

    test "throw is caught and displayed" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, "throw(:oops)"})
      assert result.status_msg =~ "**"
    end
  end

  describe "timeout handling" do
    test "long-running eval times out gracefully" do
      state = build_state()
      result = Eval.execute(state, {:eval_expression, ":timer.sleep(10_000)"}, timeout: 100)
      assert result.status_msg == "Eval timed out (0s)"
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
      assert result.status_msg == "2"
    end
  end
end
