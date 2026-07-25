defmodule MingaEditor.RenderModel.UI.PickerBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Project.Root
  alias Minga.RenderModel.UI.Picker
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.RenderModel.UI.PickerBuilder
  alias MingaEditor.State.Picker, as: PickerUIState
  alias MingaEditor.UI.Picker, as: PickerState
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectFileCandidate

  describe "build/1" do
    test "returns hidden picker when modal is not a picker" do
      model = PickerBuilder.build(build_context(nil))

      assert %Picker{visible?: false, items: [], preview_lines: nil} = model
    end

    test "maps picker state, action menu, load status, and source preview" do
      item = %Item{
        id: "one",
        label: "One",
        description: "First result",
        annotation: "enter",
        icon_color: 0x123456,
        two_line: true,
        match_positions: [0, 2]
      }

      picker = %PickerState{
        items: [item, %Item{id: "two", label: "Two"}],
        filtered: [item],
        title: "Find",
        query: "o",
        selected: 0,
        marked: %{"one" => true}
      }

      modal =
        picker_modal(
          picker,
          Minga.Test.RenderModelPickerPreviewSource,
          {[{"Open", :open}], 0},
          ">",
          :loading
        )

      model = PickerBuilder.build(build_context(modal))

      assert %Picker{visible?: true} = model
      assert model.title == "Find"
      assert model.query == "o"
      assert model.query_generation == 7
      assert model.acknowledged_query_edit_seq == 11
      assert model.selected_index == 0
      assert model.filtered_count == 1
      assert model.total_count == 2
      assert model.marked_count == 1
      assert model.has_preview?
      assert model.mode_prefix == ">"
      assert model.load_status == :loading
      assert model.action_menu.actions == ["Open"]
      assert model.action_menu.selected_index == 0
      # The builder emits wire-shaped item maps: flags packs two_line (bit 0)
      # and marked (bit 1), description/annotation default to "", icon_color
      # defaults to 0, and match_positions are preserved exactly.
      assert [
               %{
                 icon_color: 0x123456,
                 flags: 3,
                 label: "One",
                 description: "First result",
                 annotation: "enter",
                 match_positions: [0, 2]
               }
             ] = model.items

      assert model.preview_lines == [[{"preview: One", 0xABCDEF, true}]]
    end

    test "normalizes item nil defaults without dropping match_positions" do
      # Source item with nil icon_color/annotation and a match_positions list
      # larger than the wire count. The semantic builder preserves it exactly;
      # the adapter rejects the out-of-range count before encoding.
      item = %Item{
        id: "one",
        label: "One",
        description: "",
        icon_color: nil,
        annotation: nil,
        match_positions: Enum.to_list(0..300)
      }

      picker = %PickerState{items: [item], filtered: [item], title: "Find", selected: 0}
      modal = picker_modal(picker, nil, nil, "", :ready)

      model = PickerBuilder.build(build_context(modal))

      assert [wire_item] = model.items
      assert wire_item.icon_color == 0
      assert wire_item.description == ""
      assert wire_item.annotation == ""
      assert Enum.count(wire_item.match_positions) == 301
      assert wire_item.match_positions == Enum.to_list(0..300)
    end

    test "exactly 255 match_positions are preserved" do
      item = %Item{id: "one", label: "One", match_positions: Enum.to_list(0..254)}
      picker = %PickerState{items: [item], filtered: [item], title: "Find", selected: 0}
      modal = picker_modal(picker, nil, nil, "", :ready)

      model = PickerBuilder.build(build_context(modal))

      assert [%{match_positions: positions}] = model.items
      assert Enum.count(positions) == 255
    end

    test "falls back to file preview when source has GUI preview but no preview callback" do
      path = temp_file!("alpha\nbeta")
      item = %Item{id: path, label: Path.basename(path)}
      picker = %PickerState{items: [item], filtered: [item], title: "Files", selected: 0}
      modal = picker_modal(picker, MingaEditor.UI.Picker.RecentFileSource, nil, "", :ready)

      model = PickerBuilder.build(build_context(modal))

      assert model.has_preview?
      assert model.preview_lines == [[{"alpha", 0xCCCCCC, false}], [{"beta", 0xCCCCCC, false}]]
    end

    test "relative file preview uses the candidate workspace root" do
      root_path =
        Path.join(System.tmp_dir!(), "picker-preview-root-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root_path)
      File.write!(Path.join(root_path, "relative.txt"), "captured root")
      on_exit(fn -> File.rm_rf!(root_path) end)
      {:ok, root} = Root.directory(root_path)

      {:ok, candidate} = ProjectFileCandidate.new(root, "relative.txt")
      item = %Item{id: candidate, label: "relative.txt"}

      picker = %PickerState{items: [item], filtered: [item], title: "Files", selected: 0}
      modal = picker_modal(picker, MingaEditor.UI.Picker.FileSource, nil, "", :ready)

      model = PickerBuilder.build(build_context(modal))

      assert model.preview_lines == [[{"captured root", 0xCCCCCC, false}]]
    end

    test "binary file preview shows a safe placeholder" do
      path = temp_file!(<<0, 1, 2, "BEAM">>)
      item = %Item{id: path, label: Path.basename(path)}
      picker = %PickerState{items: [item], filtered: [item], title: "Files", selected: 0}
      modal = picker_modal(picker, MingaEditor.UI.Picker.RecentFileSource, nil, "", :ready)

      model = PickerBuilder.build(build_context(modal))

      assert model.preview_lines == [[{"Binary file preview unavailable", 0xCCCCCC, true}]]
    end
  end

  @spec picker_modal(PickerState.t(), module(), term(), String.t(), Picker.load_status()) ::
          term()
  defp picker_modal(picker, source, action_menu, mode_prefix, load_status) do
    {:picker,
     %{
       picker_ui: %PickerUIState{
         picker: picker,
         source: source,
         callback_source: nil,
         action_menu: action_menu,
         source_switch: source_switch(mode_prefix, source),
         load_status: load_status,
         query_generation: 7,
         acknowledged_query_edit_seq: 11
       }
     }}
  end

  @spec source_switch(String.t(), module()) :: PickerUIState.source_switch()
  defp source_switch("", _source), do: :original
  defp source_switch(prefix, source), do: {:switched, source, prefix}

  @spec build_context(term()) :: MingaEditor.Frontend.Emit.Context.t()
  defp build_context(modal) do
    ctx =
      TestHelpers.base_state(port_manager: nil)
      |> Context.from_editor_state()

    frame = %{ctx.intent.frame | shell_state: %{modal: modal}}
    %{ctx | intent: %{ctx.intent | frame: frame}}
  end

  @spec temp_file!(String.t()) :: String.t()
  defp temp_file!(content) do
    path = Path.join(System.tmp_dir!(), "minga-picker-#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
