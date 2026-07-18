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

    test "nil revisions never match, including a picker with no active fetch" do
      refute PickerState.current_fetch?(%PickerState{}, nil)
      {ps, _revision} = PickerState.begin_fetch(%PickerState{})
      refute PickerState.current_fetch?(ps, nil)
    end
  end

  describe "native query edit correlation" do
    test "a fresh query session mints a generation and clears its acknowledgement" do
      state =
        %PickerState{acknowledged_query_edit_seq: 9}
        |> PickerState.begin_query_session()

      assert state.query_generation > 0
      assert state.acknowledged_query_edit_seq == 0
    end

    test "only newer edits from the current generation are accepted" do
      picker = MingaEditor.UI.Picker.new([], title: "Native")
      state = %PickerState{query_generation: 7, acknowledged_query_edit_seq: 2}

      refute PickerState.current_query_edit?(state, 6, 3)
      refute PickerState.current_query_edit?(state, 7, 2)
      assert PickerState.current_query_edit?(state, 7, 3)

      accepted = PickerState.accept_query_edit(state, picker, 3)
      assert accepted.picker == picker
      assert accepted.acknowledged_query_edit_seq == 3
      assert PickerState.accept_query_edit(accepted, nil, 2) == accepted
    end
  end

  describe "source ownership and fetch completion" do
    test "loading state retains only semantic source and revision correlation" do
      source = {:extension, :picker_owner}
      picker = MingaEditor.UI.Picker.new([], title: "Owned")

      state = PickerState.loading(picker, __MODULE__, source, 0, nil, %{query: "x"}, :bottom)
      {state, revision} = PickerState.begin_fetch(state)

      assert PickerState.owned_by?(state, source)
      refute PickerState.owned_by?(state, {:extension, :other})
      assert state.fetch_revision == revision
      refute Map.has_key?(Map.from_struct(state), :fetch_worker)
    end

    test "success and failure update loading status without replacing correlation" do
      source = {:extension, :picker_owner}
      picker = MingaEditor.UI.Picker.new([], title: "Owned")
      state = PickerState.loading(picker, __MODULE__, source, nil, nil, nil, :bottom)
      {state, revision} = PickerState.begin_fetch(state)
      populated = MingaEditor.UI.Picker.new([], title: "Populated")

      completed = PickerState.complete_fetch(state, populated)
      assert completed.load_status == :ready
      assert completed.fetch_revision == revision
      assert completed.callback_source == source

      failed = PickerState.fail_fetch(state, "unavailable")
      assert failed.load_status == {:error, "unavailable"}
      assert failed.fetch_revision == revision
      assert failed.callback_source == source
    end
  end
end
