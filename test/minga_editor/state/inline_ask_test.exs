defmodule MingaEditor.State.InlineAskTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.State.InlineAsk

  test "headers describe line and selection anchors" do
    file_ref = buffer_ref("scratch.ex")

    line_ask = InlineAsk.new(self(), file_ref, "scratch.ex", 3)
    selection_ask = InlineAsk.new(self(), file_ref, "scratch.ex", 5, {1, 5})

    assert InlineAsk.header(line_ask) == "Ask about line 4 of scratch.ex"
    assert InlineAsk.header(selection_ask) == "Ask about lines 2–6 of scratch.ex"
  end

  test "scroll is bounded at zero" do
    ask = InlineAsk.new(self(), buffer_ref("scratch.ex"), "scratch.ex", 0)

    assert InlineAsk.scroll(ask, -1).scroll == 0
    assert ask |> InlineAsk.scroll(3) |> InlineAsk.scroll(-1) |> Map.fetch!(:scroll) == 2
  end

  test "running and answered phases own session and response" do
    session = self()
    ask = InlineAsk.new(self(), buffer_ref("scratch.ex"), "scratch.ex", 0)

    running = InlineAsk.thinking(ask, session)
    assert InlineAsk.phase(running) == {:running, session, ""}
    assert InlineAsk.running?(running)
    assert InlineAsk.session_pid(running) == session
    assert InlineAsk.response(running) == ""

    answered =
      running
      |> InlineAsk.append_response("hello")
      |> InlineAsk.append_response(" world")
      |> InlineAsk.answered()

    assert InlineAsk.answered?(answered)
    assert InlineAsk.session_pid(answered) == nil
    assert InlineAsk.response(answered) == "hello world"
  end

  test "terminal ask phases do not keep accumulating response" do
    ask = InlineAsk.new(self(), buffer_ref("scratch.ex"), "scratch.ex", 0)

    answered =
      ask
      |> InlineAsk.thinking(self())
      |> InlineAsk.append_response("done")
      |> InlineAsk.answered()

    failed = InlineAsk.fail(ask, "boom")

    assert InlineAsk.response(InlineAsk.append_response(answered, " ignored")) == "done"
    assert InlineAsk.response(InlineAsk.append_response(failed, " ignored")) == "boom"
  end

  test "store keeps independent asks per buffer and dismisses one" do
    first = start_supervised!({BufferProcess, content: "one"}, id: {:inline_ask_state, :one})
    second = start_supervised!({BufferProcess, content: "two"}, id: {:inline_ask_state, :two})
    file_ref = FileRef.from_buffer(first)

    store =
      %{}
      |> InlineAsk.put(InlineAsk.new(first, file_ref, "one.ex", 0))
      |> InlineAsk.put(InlineAsk.new(second, file_ref, "two.ex", 0))

    {store, nil} = InlineAsk.dismiss(store, second)
    assert InlineAsk.put(store, %{buffer_pid: first}) == store
    refute InlineAsk.session?(%{first => %{buffer_pid: first, session: self()}}, self())
    assert {%{}, nil} = InlineAsk.dismiss(%{first => %{buffer_pid: first}}, first)

    assert InlineAsk.active(store, first).file_label == "one.ex"
    assert InlineAsk.active(store, second) == nil
  end

  defp buffer_ref(name) do
    %FileRef{kind: :buffer, display_name: name, buffer_pid: self()}
  end
end
