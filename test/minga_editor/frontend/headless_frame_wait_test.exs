defmodule MingaEditor.Frontend.HeadlessFrameWaitTest do
  use ExUnit.Case, async: true

  alias Minga.Test.HeadlessPort
  alias MingaEditor.Frontend.Protocol

  test "an input-correlated waiter skips unrelated committed frames" do
    port = start_supervised!({HeadlessPort, width: 20, height: 8})
    next = HeadlessPort.prepare_await(port)
    exact = HeadlessPort.prepare_await(port, 42)

    :accepted =
      HeadlessPort.send_commands(port, [
        Protocol.encode_begin_frame(1, 0, 0),
        Protocol.encode_commit_frame(1, 41),
        Protocol.encode_begin_frame(2, 1, 0),
        Protocol.encode_commit_frame(2, 42)
      ])

    assert {:ok, %{input_seq: 41}} = HeadlessPort.collect_frame(next)
    assert {:ok, %{input_seq: 42}} = HeadlessPort.collect_frame(exact)
  end
end
