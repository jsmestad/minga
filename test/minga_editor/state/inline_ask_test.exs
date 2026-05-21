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

  test "store keeps independent asks per buffer and dismisses one" do
    first = start_supervised!({BufferProcess, content: "one"}, id: {:inline_ask_state, :one})
    second = start_supervised!({BufferProcess, content: "two"}, id: {:inline_ask_state, :two})
    file_ref = FileRef.from_buffer(first)

    store =
      %{}
      |> InlineAsk.put(InlineAsk.new(first, file_ref, "one.ex", 0))
      |> InlineAsk.put(InlineAsk.new(second, file_ref, "two.ex", 0))

    {store, nil} = InlineAsk.dismiss(store, second)

    assert InlineAsk.active(store, first).file_label == "one.ex"
    assert InlineAsk.active(store, second) == nil
  end

  defp buffer_ref(name) do
    %FileRef{kind: :buffer, display_name: name, buffer_pid: self()}
  end
end
