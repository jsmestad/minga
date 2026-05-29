defmodule MingaEditor.RenderModel.UI.PickerBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Picker
  alias MingaEditor.RenderModel.UI.PickerBuilder
  alias MingaEditor.State.Buffers
  alias MingaEditor.UI.Picker, as: PickerState
  alias MingaEditor.UI.Picker.Item

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
      assert model.selected_index == 0
      assert model.filtered_count == 1
      assert model.total_count == 2
      assert model.marked_count == 1
      assert model.has_preview?
      assert model.mode_prefix == ">"
      assert model.load_status == :loading
      assert model.action_menu.actions == ["Open"]
      assert model.action_menu.selected_index == 0
      assert [%{id: "one", marked?: true, two_line?: true, match_positions: [0, 2]}] = model.items
      assert model.preview_lines == [[{"preview: One", 0xABCDEF, true}]]
    end

    test "falls back to file preview when source has GUI preview but no preview callback" do
      path = temp_file!("alpha\nbeta")
      item = %Item{id: path, label: Path.basename(path)}
      picker = %PickerState{items: [item], filtered: [item], title: "Files", selected: 0}
      modal = picker_modal(picker, MingaEditor.UI.Picker.FileSource, nil, "", :ready)

      model = PickerBuilder.build(build_context(modal))

      assert model.has_preview?
      assert model.preview_lines == [[{"alpha", 0xCCCCCC, false}], [{"beta", 0xCCCCCC, false}]]
    end
  end

  @spec picker_modal(PickerState.t(), module(), term(), String.t(), Picker.load_status()) ::
          term()
  defp picker_modal(picker, source, action_menu, mode_prefix, load_status) do
    {:picker,
     %{
       picker_ui: %{
         picker: picker,
         source: source,
         action_menu: action_menu,
         mode_prefix: mode_prefix,
         load_status: load_status
       }
     }}
  end

  @spec build_context(term()) :: MingaEditor.Frontend.Emit.Context.t()
  defp build_context(modal) do
    %MingaEditor.Frontend.Emit.Context{
      port_manager: self(),
      capabilities: MingaEditor.Frontend.Capabilities.default(),
      theme: %{fg: 0xCCCCCC},
      font_registry: MingaEditor.UI.FontRegistry.new(),
      windows: %MingaEditor.State.Windows{map: %{}, active: 1},
      layout: %MingaEditor.Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 24},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{}
      },
      shell: MingaEditor.Shell.Traditional,
      shell_state: %{modal: modal},
      buffers: %Buffers{},
      highlight: %{highlights: %{}}
    }
  end

  @spec temp_file!(String.t()) :: String.t()
  defp temp_file!(content) do
    path = Path.join(System.tmp_dir!(), "minga-picker-#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
