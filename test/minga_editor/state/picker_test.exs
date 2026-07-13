defmodule MingaEditor.State.PickerTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Picker, as: PickerState

  describe "begin_fetch/1 and current_fetch?/2" do
    test "marks the picker loading and mints a fresh revision" do
      {ps, revision} = PickerState.begin_fetch(%PickerState{})

      assert ps.load_status == :loading
      assert is_reference(revision)
      assert ps.fetch_revision == revision
    end

    test "only the live revision is current (latest-wins, not FIFO)" do
      {ps, first} = PickerState.begin_fetch(%PickerState{})
      assert PickerState.current_fetch?(ps, first)

      # A newer search / project switch / reopen mints a new revision on the same
      # picker. The older in-flight fetch is now stale and must be dropped, even
      # though it was requested first. This is the latest-wins behavior the ticket
      # requires, distinct from serialized mutation effects.
      {ps, second} = PickerState.begin_fetch(ps)

      refute PickerState.current_fetch?(ps, first)
      assert PickerState.current_fetch?(ps, second)
    end

    test "a nil revision never matches a picker that has a live fetch" do
      {ps, _revision} = PickerState.begin_fetch(%PickerState{})
      refute PickerState.current_fetch?(ps, nil)
    end
  end
end
