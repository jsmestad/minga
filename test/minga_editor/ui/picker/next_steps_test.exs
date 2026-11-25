defmodule MingaEditor.UI.Picker.NextStepsTest do
  @moduledoc """
  A picker whose source offers next steps when nothing matches: the rows take the place of results, and a picker with nothing to filter becomes a list with list keys.
  """

  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.EmptyList
  alias Minga.Test.NextStepsPickerSource
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.PickerBuilder
  alias MingaEditor.FocusOwner
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Empty

  @enter 13
  @escape 27
  @ctrl 0x02

  defp open(labels),
    do: PickerUI.open(TestHelpers.base_state(), NextStepsPickerSource, %{labels: labels})

  defp picker(state) do
    {:picker, %{picker_ui: %{picker: picker}}} = state.shell_runtime.state.modal
    picker
  end

  defp rows(state), do: Enum.map(picker(state).filtered, &{&1.label, &1.annotation})

  defp type(state, text),
    do: text |> String.to_charlist() |> Enum.reduce(state, &PickerUI.handle_key(&2, &1, 0))

  describe "a source with no candidates" do
    test "opens with its next steps as rows, the first selected, and takes list keys" do
      state = open([])

      assert %Empty{
               title: "Nothing here yet.",
               why: "This source lists what its context gives it."
             } =
               picker(state).empty

      assert rows(state) == [{"Add a folder", "SPC p a"}, {"Open a file", "SPC f f"}]
      assert Picker.selected_item(picker(state)).label == "Add a folder"
      assert Picker.list_keys?(picker(state))
      assert %{responder: :editor_view, surface: :picker} = FocusOwner.derive(state)
    end

    test "j and k move, other letters type nothing, and ↩ runs the selected step's command" do
      state = open([]) |> PickerUI.handle_key(?j, 0) |> PickerUI.handle_key(?x, 0)

      assert picker(state).query == ""
      assert Picker.selected_item(picker(state)).label == "Open a file"

      assert Picker.selected_item(PickerUI.handle_key(state, ?k, 0) |> picker()).label ==
               "Add a folder"

      assert {closed, {:execute_command, :find_file}} = PickerUI.handle_key(state, @enter, 0)
      assert closed.shell_runtime.state.modal == :none
    end

    test "a paste or a late native edit types nothing into it" do
      state = open([])
      pasted = PickerUI.append_query(state, "zz")
      {:picker, %{picker_ui: picker_state}} = state.shell_runtime.state.modal

      edited =
        PickerUI.replace_query(
          state,
          picker_state.query_generation,
          picker_state.acknowledged_query_edit_seq + 1,
          "zz"
        )

      assert picker(pasted).query == ""
      assert picker(edited).query == ""
    end

    test "the render model carries the header, list keys, and counts no matches" do
      model = open([]) |> Context.from_editor_state() |> PickerBuilder.build()

      assert %EmptyList{title: "Nothing here yet.", actions: []} = model.empty
      assert model.list_keys?
      assert model.filtered_count == 0

      assert Enum.map(model.items, &{&1.label, &1.annotation}) == [
               {"Add a folder", "SPC p a"},
               {"Open a file", "SPC f f"}
             ]
    end

    test "the keys sent to frontends for the selection preview are the keys that move it here" do
      list = open([]) |> Context.from_editor_state() |> PickerBuilder.build()
      typing = open(["alpha", "beta"]) |> Context.from_editor_state() |> PickerBuilder.build()

      moves = fn model ->
        Map.new(model.movement_keys, &{{&1.codepoint, &1.modifiers}, &1.movement})
      end

      # With nothing to filter, plain j and k move the selection, so a frontend may preview them.
      assert %{{?j, 0} => :next, {?k, 0} => :previous} = moves.(list)

      # A picker that takes text types j and k into the query: no frontend may move for them.
      refute Map.has_key?(moves.(typing), {?j, 0})
      refute Map.has_key?(moves.(typing), {?k, 0})

      # Every key in the list moves the selection the way it says, and types nothing.
      for %{codepoint: codepoint, modifiers: modifiers, movement: movement} <- list.movement_keys do
        {start, expected} =
          case movement do
            :next -> {open([]), "Open a file"}
            :previous -> {PickerUI.handle_key(open([]), ?j, 0), "Add a folder"}
          end

        moved = PickerUI.handle_key(start, codepoint, modifiers)

        assert Picker.selected_item(picker(moved)).label == expected
        assert picker(moved).query == ""
      end
    end

    test "q and esc close it" do
      for key <- [?q, @escape] do
        assert PickerUI.handle_key(open([]), key, 0).shell_runtime.state.modal == :none
      end
    end
  end

  describe "a query that matches nothing" do
    test "offers the rows while typing keeps editing the query, and a match replaces them" do
      state = open(["alpha", "beta"]) |> type("zz")

      assert picker(state).query == "zz"
      assert picker(state).empty.title == "Nothing matches “zz”."
      refute Picker.list_keys?(picker(state))
      assert %{responder: :picker_query} = FocusOwner.derive(state)
      assert rows(state) == [{"Add a folder", "SPC p a"}, {"Open a file", "SPC f f"}]

      # ⌃J moves through the rows; plain j is text in a live prompt.
      moved = PickerUI.handle_key(state, ?j, @ctrl)
      assert Picker.selected_item(picker(moved)).label == "Open a file"

      matched = state |> PickerUI.handle_key(127, 0) |> PickerUI.handle_key(127, 0) |> type("al")
      assert picker(matched).empty == nil
      assert Enum.map(picker(matched).filtered, & &1.label) == ["alpha"]
    end

    test "next-step rows have no act menu and cannot be marked" do
      state = open(["alpha"]) |> type("zz")

      acted = PickerUI.handle_key(state, ?., @ctrl)
      assert {:picker, %{picker_ui: %{action_menu: nil}}} = acted.shell_runtime.state.modal
      assert Picker.toggle_mark(picker(state)).marked == %{}
    end
  end

  describe "offer_empty/2" do
    test "replaces an empty result list and lasts until the next filter" do
      empty = %Empty{title: "Nothing.", rows: [Empty.row(:one, "One", "1")]}

      offered =
        Picker.new([%MingaEditor.UI.Picker.Item{id: :a, label: "alpha"}])
        |> Picker.filter("zz")
        |> Picker.offer_empty(empty)

      assert [%{label: "One"}] = offered.filtered
      assert offered.empty == Empty.header(empty)
      assert Picker.filter(offered, "al").empty == nil

      assert Picker.offer_empty(Picker.filter(offered, "al"), empty).filtered
             |> hd()
             |> Map.get(:label) == "alpha"
    end
  end
end
