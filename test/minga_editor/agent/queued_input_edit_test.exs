defmodule MingaEditor.Agent.QueuedInputEditTest do
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias MingaEditor.Agent.QueuedInputEdit

  test "a second Edit while the exact input loads does not schedule another read" do
    ctx = start_editor("scratch")
    owner = self()
    origin = {1, self(), "conversation"}

    request = fn identity, :read ->
      send(owner, {:reading, identity, self()})

      receive do
        :finish_read -> {:ok, "original input"}
      end
    end

    :sys.replace_state(ctx.editor, &QueuedInputEdit.open(&1, origin, {1, 1}, request))
    assert_receive {:reading, {1, 1}, worker}

    :sys.replace_state(ctx.editor, &QueuedInputEdit.open(&1, origin, {2, 1}, request))
    assert notice_message(ctx) == "A queued input is already loading."
    refute_received {:reading, {2, 1}, _worker}

    send(worker, :finish_read)
  end
end
