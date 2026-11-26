defmodule MingaEditor.Agent.QueueSurfaceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.QueuedInputSummary
  alias MingaEditor.Agent.QueueSurface

  test "opening and closing restores the first focus, even when the queue opens twice" do
    origin = {1, self(), "saved"}
    unbound = %QueueSurface{}
    assert :not_focused = unbound |> QueueSurface.open(:transcript) |> QueueSurface.close()

    for return <- [:composer, :transcript] do
      idle = QueueSurface.bind(unbound, origin)
      assert :not_focused = QueueSurface.close(idle)
      refute QueueSurface.visible?(idle)

      open = idle |> QueueSurface.open(return) |> QueueSurface.open(:transcript)
      assert QueueSurface.visible?(open)
      assert QueueSurface.focused?(open)
      assert selected_identity(QueueSurface.move(open, :next)) == nil
      assert {:closed, ^return, closed} = QueueSurface.close(QueueSurface.move(open, :next))
      refute QueueSurface.visible?(closed)
    end
  end

  test "passive queues stay visible after focus leaves, including a removal that cannot be sent" do
    origin = {1, self(), "saved"}

    for {pending, removed, visible?} <- [
          {[], [], false},
          {[row(1)], [], true},
          {[], [row(2)], true}
        ] do
      open = %QueueSurface{} |> QueueSurface.bind(origin) |> QueueSurface.open(:composer)
      current = QueueSurface.refresh(open, origin, %{pending: pending, removed: removed})
      assert {:closed, :composer, closed} = QueueSurface.close(current)
      assert QueueSurface.visible?(closed) == visible?
    end
  end

  test "moving, draining, and revising rows keep the cursor on the same pending input" do
    origin = {1, self(), "saved"}
    one = row(1)
    two = row(2)
    three = row(3)
    start = %QueueSurface{} |> QueueSurface.bind(origin) |> refresh(origin, [one, two, three])

    assert selected_identity(QueueSurface.move(start, :previous)) == {1, 1}
    selected = QueueSurface.move(start, :next)
    assert selected_identity(selected) == {2, 1}

    for {rows, expected} <- [
          {[two, three], {2, 1}},
          {[three, one, row(2, 2)], {2, 2}},
          {[one, three], {3, 1}},
          {[one], {1, 1}},
          {[], nil}
        ] do
      assert selected_identity(refresh(selected, origin, rows)) == expected
    end

    last = QueueSurface.move(selected, :next)
    assert selected_identity(QueueSurface.move(last, :next)) == {3, 1}
  end

  test "a delayed click cannot select a revised row or a removed input" do
    origin = {1, self(), "saved"}

    queue =
      %QueueSurface{}
      |> QueueSurface.bind(origin)
      |> QueueSurface.refresh(origin, %{pending: [row(1), row(2, 3)], removed: [row(3)]})

    assert :stale_row = QueueSurface.select(queue, {2, 2})
    assert :stale_row = QueueSurface.select(queue, {3, 1})
    assert {:ok, selected} = QueueSurface.select(queue, {2, 3})
    assert selected_identity(selected) == {2, 3}
  end

  test "a delayed snapshot from the previous tab does not populate or focus the new tab's queue" do
    previous_origin = {1, self(), "one"}
    origin = {2, self(), "two"}

    previous =
      %QueueSurface{} |> QueueSurface.bind(previous_origin) |> QueueSurface.open(:composer)

    queue = QueueSurface.bind(previous, origin)
    stale = refresh(queue, previous_origin, [row(1)])

    refute QueueSurface.visible?(stale)
    assert selected_identity(stale) == nil
    assert selected_identity(refresh(stale, origin, [row(2)])) == {2, 1}
  end

  defp refresh(queue, origin, pending),
    do: QueueSurface.refresh(queue, origin, %{pending: pending, removed: []})

  defp selected_identity(queue) do
    case QueueSurface.selected(queue) do
      nil -> nil
      %QueuedInputSummary{identity: identity} -> identity
    end
  end

  defp row(id, revision \\ 1),
    do: %QueuedInputSummary{
      identity: {id, revision},
      kind: :follow_up,
      preview: "",
      attachment_count: 0
    }
end
