defmodule MingaEditor.State.PickerTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Theme

  describe "semantic activation offers" do
    test "resolves only the exact item offered by the current snapshot" do
      first = %Item{id: :first, label: "First"}
      second = %Item{id: :second, label: "Second"}

      state =
        %PickerState{picker: Picker.new([first, second], title: "Choose")}
        |> PickerState.refresh_activation_offer()

      generation = state.activation_offer.generation
      assert {:ok, 1, ^second} = PickerState.resolve_item_activation(state, generation, 2)
      assert :error = PickerState.resolve_item_activation(state, generation + 1, 2)
      assert :error = PickerState.resolve_item_activation(state, generation, 99)

      reordered = PickerState.update_picker(state, Picker.new([second, first], title: "Choose"))
      assert :error = PickerState.resolve_item_activation(reordered, generation, 2)
    end

    test "action offer captures the item and invalidates after the menu changes" do
      first = %Item{id: :first, label: "First"}
      picker = Picker.new([first], title: "Choose")

      state =
        %PickerState{picker: picker}
        |> PickerState.open_action_menu([{"Open", :open}], first)

      generation = state.activation_offer.generation

      assert {:ok, {"Open", :open}, ^first} =
               PickerState.resolve_action_activation(state, generation, 1)

      closed = PickerState.close_action_menu(state)
      assert :error = PickerState.resolve_action_activation(closed, generation, 1)
    end

    test "action-menu transitions own open, movement, and close across menu states" do
      item = %Item{id: :first, label: "First"}
      actions = [{"Open", :open}, {"Delete", :delete}]
      closed = %PickerState{picker: Picker.new([item], title: "Choose")}

      assert PickerState.open_action_menu(closed, [], item) == closed
      assert PickerState.move_action_menu_selection(closed, :next) == closed
      assert PickerState.move_action_menu_selection(closed, :previous) == closed
      assert PickerState.close_action_menu(closed) == closed

      opened = PickerState.open_action_menu(closed, actions, item)
      assert opened.action_menu == {actions, 0, item}

      for {direction, expected_index} <- [next: 1, previous: 1] do
        moved = PickerState.move_action_menu_selection(opened, direction)

        assert moved.action_menu == {actions, expected_index, item}
        refute moved.activation_offer.generation == opened.activation_offer.generation
      end

      reopened =
        opened
        |> PickerState.move_action_menu_selection(:next)
        |> PickerState.move_action_menu_selection(:next)

      assert reopened.action_menu == {actions, 0, item}

      closed_again = PickerState.close_action_menu(opened)
      assert closed_again.action_menu == nil
      refute closed_again.activation_offer.generation == opened.activation_offer.generation
    end

    test "offers at most the rendered result window" do
      items = for id <- 1..150, do: %Item{id: id, label: Integer.to_string(id)}

      state =
        %PickerState{picker: Picker.new(items, title: "Bounded")}
        |> PickerState.refresh_activation_offer()

      assert Enum.count_until(state.activation_offer.items, 101) == 100

      assert :error =
               PickerState.resolve_item_activation(state, state.activation_offer.generation, 101)
    end
  end

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

    test "starting a refresh invalidates identities captured from the old result set" do
      item = %Item{id: :old, label: "Old"}

      state =
        %PickerState{picker: Picker.new([item], title: "Async")}
        |> PickerState.refresh_activation_offer()

      generation = state.activation_offer.generation
      {loading, _revision} = PickerState.begin_fetch(state)

      assert :error = PickerState.resolve_item_activation(loading, generation, 1)
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

  describe "source switching" do
    test "retarget and restore preserve picker-session state as one owned transition" do
      original_item = %Item{id: :original, label: "Original"}
      original_picker = Picker.new([original_item], title: "Files")
      target_picker = Picker.new([], title: "Search")
      theme = Theme.get!(Theme.default())
      stale_revision = make_ref()

      state =
        %PickerState{
          picker: original_picker,
          source: MingaEditor.UI.Picker.FileSource,
          restore: 3,
          restore_theme: theme,
          context: %{query: "needle"},
          query_generation: 7,
          acknowledged_query_edit_seq: 2,
          load_status: {:error, "old"},
          fetch_revision: stale_revision
        }
        |> PickerState.refresh_activation_offer()

      assert {:ok, 0, ^original_item} =
               PickerState.resolve_item_activation(state, state.activation_offer.generation, 1)

      switched =
        PickerState.retarget(
          state,
          target_picker,
          {MingaEditor.UI.Picker.ProjectSearchSource, nil, :top},
          {:switch, "#"}
        )

      assert switched.source == MingaEditor.UI.Picker.ProjectSearchSource
      assert switched.source_switch == {:switched, MingaEditor.UI.Picker.FileSource, "#"}
      assert PickerState.mode_prefix(switched) == "#"
      assert switched.load_status == :ready
      assert switched.fetch_revision == nil
      assert switched.restore == 3
      assert switched.restore_theme == theme
      assert switched.context == %{query: "needle"}
      assert switched.query_generation == 7
      assert switched.acknowledged_query_edit_seq == 2

      assert :error =
               PickerState.resolve_item_activation(switched, state.activation_offer.generation, 1)

      restored =
        PickerState.retarget(
          switched,
          original_picker,
          {MingaEditor.UI.Picker.FileSource, nil, :bottom},
          :restore
        )

      assert restored.source == MingaEditor.UI.Picker.FileSource
      assert restored.source_switch == :original
      assert PickerState.mode_prefix(restored) == ""
      assert restored.restore == 3
      assert restored.restore_theme == theme
      assert restored.context == %{query: "needle"}
      assert restored.query_generation == 7
      assert restored.acknowledged_query_edit_seq == 2
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
