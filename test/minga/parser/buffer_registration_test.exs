defmodule Minga.Parser.BufferRegistrationTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferRegistration

  test "coalesces changes during one parse into a trailing pump" do
    registration = BufferRegistration.new(1, %BufferConfig{language: "elixir"}, make_ref())
    token = make_ref()

    assert BufferRegistration.pumpable?(registration)
    refute BufferRegistration.synchronized?(registration, 3)

    awaiting = BufferRegistration.await_snapshot(registration, token)
    refute BufferRegistration.pumpable?(awaiting)
    assert BufferRegistration.awaiting?(awaiting, token)
    refute BufferRegistration.awaiting?(awaiting, make_ref())

    parsing = BufferRegistration.begin_parse(awaiting, 1, 3, true)
    dirty = BufferRegistration.mark_dirty(parsing, 5)
    refute BufferRegistration.pumpable?(dirty)

    assert {:ok, completed} = BufferRegistration.complete_parse(dirty, 1)
    assert completed.synced_sequence == 3
    assert BufferRegistration.synchronized?(completed, 3)
    assert BufferRegistration.accepts_version?(completed, 1)
    refute BufferRegistration.accepts_version?(completed, 2)
    assert BufferRegistration.pumpable?(completed)
  end

  test "stale completion cannot finish a newer parse" do
    registration =
      BufferRegistration.new(1, %BufferConfig{language: "elixir"}, make_ref())
      |> BufferRegistration.await_snapshot(make_ref())
      |> BufferRegistration.begin_parse(4, 7, true)

    assert BufferRegistration.complete_parse(registration, 3) == :stale
    assert {:ok, completed} = BufferRegistration.complete_parse(registration, 4)
    assert completed.synced_sequence == 7
    refute BufferRegistration.pumpable?(completed)
  end

  test "restart discards in-flight work and requires a full snapshot" do
    registration =
      BufferRegistration.new(1, %BufferConfig{language: "elixir"}, make_ref())
      |> BufferRegistration.await_snapshot(make_ref())
      |> BufferRegistration.begin_parse(2, 4, true)
      |> BufferRegistration.restart()

    assert registration.phase == :idle
    assert registration.synced_sequence == 0
    assert registration.force_full?
    assert BufferRegistration.snapshot_cursor(registration) == :full
    assert BufferRegistration.pumpable?(registration)
  end
end
