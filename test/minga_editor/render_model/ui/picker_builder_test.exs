defmodule MingaEditor.RenderModel.UI.PickerBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.Language.Highlight.Span
  alias Minga.Project.Root
  alias Minga.RenderModel.UI.Picker
  alias MingaAgent.Session
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.RenderModel.UI.PickerBuilder
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Parser
  alias MingaEditor.State.Picker, as: PickerUIState
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.Picker.AgentDraftAttachmentSource
  alias MingaEditor.UI.Picker.AgentHistorySource
  alias MingaEditor.UI.Picker.Context, as: PickerContext
  alias MingaEditor.UI.Picker, as: PickerState
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectFileCandidate
  alias MingaEditor.UI.Picker.RecentFileSource

  test "Unicode-heavy retained history and its selected preview fit the shared wire frame" do
    session =
      start_supervised!({Session, provider: Minga.Test.SessionMockProvider, persist?: false})

    text = String.duplicate("👨‍👩‍👧‍👦", 3_000)

    for _ <- 1..25, do: :ok = Session.add_system_message(session, text)
    %{connection: %{target: target}} = Session.editor_snapshot(session)

    context =
      TestHelpers.base_state(port_manager: nil)
      |> PickerContext.from_editor_state(%{origin: {1, target}, source: target, anchor: :tail})

    assert {:ok, [earlier | retained] = items, _meta} = AgentHistorySource.async_fetch(context)
    assert earlier.label == "Earlier retained messages"
    assert length(retained) == 24

    picker =
      items
      |> PickerState.new(title: AgentHistorySource.title(), max_visible: length(items))
      |> PickerState.move_down()

    model =
      picker
      |> picker_modal(AgentHistorySource, nil, "", :ready)
      |> build_context()
      |> PickerBuilder.build()

    assert length(model.items) == 25
    assert [[{preview, _, false}], [{notice, _, false}]] = model.preview_lines
    assert String.valid?(preview)
    assert String.starts_with?(text, preview)
    assert notice =~ "copy the full text"
    packet = PickerEncoder.encode_command(model)
    assert :binary.match(packet, preview) != :nomatch
    assert :binary.match(packet, notice) != :nomatch
  end

  test "Changes encodes a full long-path offer and retains exact activation identity" do
    source = MingaEditor.UI.Picker.AgentChangesSource
    offer = MingaEditor.State.Picker.ActivationOffer
    folders = String.duplicate("folder/", 100)
    files = Enum.map(1..100, &%{path: "component-#{&1}/#{folders}file.ex", entry_count: 1})
    path = "component-100/#{folders}file.ex"

    items =
      TestHelpers.base_state()
      |> PickerContext.from_editor_state(%{files: files, origin: :fixture})
      |> source.candidates()

    picker = PickerState.new(items, title: source.title(), max_visible: 100)

    model =
      picker |> picker_modal(source, nil, "", :ready) |> build_context() |> PickerBuilder.build()

    assert length(model.items) == 100
    assert is_binary(PickerEncoder.encode_command(model))

    searched = PickerState.filter(picker, path)
    modal = {:picker, %{picker_ui: ui}} = picker_modal(searched, source, nil, "", :ready)
    model = modal |> build_context() |> PickerBuilder.build()
    assert is_binary(PickerEncoder.encode_command(model))
    assert [%{activation_id: id} | _] = model.items

    assert {:ok, _, %Item{id: ^path}} =
             offer.resolve_item(ui.activation_offer, model.activation_generation, id)
  end

  test "Changes shows the distinguishing directory for files with the same name" do
    source = MingaEditor.UI.Picker.AgentChangesSource
    root = "/Users/agent/projects/a-long-path/with-the-same-prefix"
    suffix = "shared/nested/deep/identity.txt"
    first = Path.join(root, "component-a/#{suffix}")
    second = Path.join(root, "component-b/#{suffix}")
    files = [%{path: first, entry_count: 1}, %{path: second, entry_count: 1}]

    items =
      TestHelpers.base_state()
      |> PickerContext.from_editor_state(%{files: files, origin: :fixture})
      |> source.candidates()

    assert [
             %Item{id: ^first, label: "component-a/" <> ^suffix},
             %Item{id: ^second, label: "component-b/" <> ^suffix}
           ] = items

    picker = items |> PickerState.new() |> PickerState.filter(second)
    assert %Item{id: ^second} = PickerState.selected_item(picker)
  end

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
        status: MingaEditor.UI.Picker.Item.Status.new(:warn, "Ready · 82%"),
        active: true,
        group: "ChatGPT",
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
          {[{"Open", :open}], 0, item},
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
      assert model.action_menu.activation_ids == [2]
      assert model.action_menu.selected_index == 0

      # The builder emits wire-shaped item maps: flags packs marked (bit 1) and active (bit 3), the
      # status chip flattens into text and tone, description/annotation default to "", icon_color
      # defaults to 0, and match_positions are preserved exactly.
      assert [
               %{
                 icon_color: 0x123456,
                 flags: 0b1010,
                 label: "One",
                 description: "First result",
                 annotation: "enter",
                 match_positions: [0, 2],
                 activation_id: 1,
                 status: "Ready · 82%",
                 status_tone: :warn,
                 group: "ChatGPT"
               }
             ] = model.items

      assert model.preview_lines == [[{"preview: One", 0xABCDEF, true}]]
    end

    test "presents and offers activation for the selected command past the first results page" do
      items = for id <- 1..240, do: %Item{id: id, label: "Command #{id}"}

      picker =
        PickerState.new(items, results: :all)
        |> PickerState.filter("command")
        |> PickerState.move_up()

      {:picker, %{picker_ui: picker_ui}} = modal = picker_modal(picker, nil, nil, "", :ready)
      model = PickerBuilder.build(build_context(modal))
      activation_id = model.selected_item_id

      assert model.filtered_count == 240

      assert %{label: "Command 240", activation_id: ^activation_id} =
               Enum.at(model.items, model.selected_index)

      assert {:ok, 239, %Item{id: 240}} =
               PickerUIState.resolve_item_activation(
                 picker_ui,
                 model.activation_generation,
                 activation_id
               )
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
      # No status chip, no group and no flags: the row keeps the inline layout file and command
      # pickers use, with no section header.
      assert {wire_item.status, wire_item.status_tone, wire_item.flags} == {"", :none, 0}
      assert wire_item.group == ""
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

    test "disk preview preserves CRLF text and the empty 50th row" do
      rows = ["é\r" | List.duplicate("middle", 48)] ++ [""]
      path = temp_file!(Enum.join(rows ++ ["not previewed"], "\n"))

      model = path |> file_picker_modal() |> build_context() |> PickerBuilder.build()

      assert model.has_preview?
      assert model.preview_lines == Enum.map(rows, &[{&1, 0xCCCCCC, false}])
    end

    test "disk preview preserves the empty line after a final newline and in an empty file" do
      for {content, rows} <- [{"", [""]}, {"x\n", ["x", ""]}] do
        path = temp_file!(content)
        model = path |> file_picker_modal() |> build_context() |> PickerBuilder.build()

        assert model.preview_lines == Enum.map(rows, &[{&1, 0xCCCCCC, false}])
      end
    end

    test "highlighted live preview uses the parent buffer's first 50 lines and byte offsets" do
      path = temp_file!("stale disk text")
      buffer = start_supervised!({Buffer, file_path: path})
      long_line = String.duplicate("a", 16_384)
      lines = ["é\r", "x", long_line] ++ List.duplicate("middle", 46) ++ ["", "not previewed"]
      assert :ok = Buffer.replace_content(buffer, Enum.join(lines, "\n"))

      highlight =
        Highlight.new(%{"keyword" => [fg: 0x123456, bold: true]})
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(1, [Span.new(4, 5, 0)])

      state = TestHelpers.base_state(port_manager: nil)
      buffers = Buffers.add_background(state.workspace.buffers, buffer)
      highlighting = Highlighting.set_highlights(%Highlighting{}, %{buffer => highlight})

      state = %{
        state
        | workspace: SessionState.set_buffers(state.workspace, buffers),
          parser: Parser.accept_highlighting(state.parser, highlighting)
      }

      model = path |> file_picker_modal() |> build_context(state) |> PickerBuilder.build()

      assert length(model.preview_lines) == 50

      assert [[{"é\r", 0xCCCCCC, false}], [{"x", 0x123456, true}], [{^long_line, _, false}] | _] =
               model.preview_lines

      assert List.last(model.preview_lines) == [{"", 0xCCCCCC, false}]
    end

    test "an empty source preview does not fall back to disk" do
      path = temp_file!("not previewed")
      item = %Item{id: path, label: "Empty preview", meta: %{rows: []}}
      picker = PickerState.new([item], title: "Files")
      modal = picker_modal(picker, AgentDraftAttachmentSource, nil, "", :ready)

      assert PickerBuilder.build(build_context(modal)).preview_lines == []
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

    test "NUL or invalid UTF-8 after the 50th row still yields the binary placeholder" do
      for binary_tail <- [<<0>>, <<255>>] do
        path = temp_file!(String.duplicate("text\n", 50) <> binary_tail)
        model = path |> file_picker_modal() |> build_context() |> PickerBuilder.build()

        assert model.preview_lines == [[{"Binary file preview unavailable", 0xCCCCCC, true}]]
      end
    end
  end

  @spec picker_modal(PickerState.t(), module(), term(), String.t(), Picker.load_status()) ::
          term()
  defp picker_modal(picker, source, action_menu, mode_prefix, load_status) do
    {:picker,
     %{
       picker_ui:
         %PickerUIState{
           picker: picker,
           source: source,
           callback_source: nil,
           action_menu: action_menu,
           source_switch: source_switch(mode_prefix, source),
           load_status: load_status,
           query_generation: 7,
           acknowledged_query_edit_seq: 11
         }
         |> PickerUIState.refresh_activation_offer()
     }}
  end

  describe "movement keys" do
    @ctrl 0x02

    defp movement_model(state) do
      [%Item{id: :one, label: "one"}, %Item{id: :two, label: "two"}]
      |> PickerState.new(title: "Files")
      |> picker_modal(RecentFileSource, nil, "", :ready)
      |> build_context(state)
      |> PickerBuilder.build()
    end

    defp state_with_keymap(keymap_server) do
      state = TestHelpers.base_state(port_manager: nil)

      %{
        state
        | interaction: MingaEditor.State.Interaction.new(keymap_server: keymap_server)
      }
    end

    test "are the picker scope's one-row movement keys and never a plain letter" do
      keymap = start_supervised!({Minga.Keymap.Active, name: nil})
      model = movement_model(state_with_keymap(keymap))

      keys = Map.new(model.movement_keys, &{{&1.codepoint, &1.modifiers}, &1.movement})

      assert keys == %{
               {?j, @ctrl} => :next,
               {57_353, 0} => :next,
               {0xF701, 0} => :next,
               {?k, @ctrl} => :previous,
               {57_352, 0} => :previous,
               {0xF700, 0} => :previous
             }

      refute Map.has_key?(keys, {?j, 0})
      refute Map.has_key?(keys, {?k, 0})
    end

    test "follow a user override of the picker scope" do
      keymap = start_supervised!({Minga.Keymap.Active, name: nil})
      Minga.Keymap.Active.bind(keymap, {:picker, :insert}, "C-n", :picker_next, "Next")
      Minga.Keymap.Active.bind(keymap, {:picker, :insert}, "C-j", :picker_select, "Open")

      keys =
        state_with_keymap(keymap)
        |> movement_model()
        |> Map.fetch!(:movement_keys)
        |> Map.new(&{{&1.codepoint, &1.modifiers}, &1.movement})

      assert keys[{?n, @ctrl}] == :next
      refute Map.has_key?(keys, {?j, @ctrl})
    end

    test "every sent key runs the movement it names when it reaches the picker" do
      keymap = start_supervised!({Minga.Keymap.Active, name: nil})
      Minga.Keymap.Active.bind(keymap, {:picker, :insert}, "C-n", :picker_next, "Next")
      model = movement_model(state_with_keymap(keymap))

      for key <- model.movement_keys do
        command = Map.fetch!(%{next: :picker_next, previous: :picker_prev}, key.movement)

        assert {:command, ^command} =
                 Minga.Keymap.resolve_scoped_key(
                   :picker,
                   :insert,
                   {key.codepoint, key.modifiers},
                   keymap_server: keymap
                 )
      end
    end
  end

  @spec source_switch(String.t(), module()) :: PickerUIState.source_switch()
  defp source_switch("", _source), do: :original
  defp source_switch(prefix, source), do: {:switched, source, prefix}

  @spec file_picker_modal(String.t()) :: term()
  defp file_picker_modal(path) do
    picker = PickerState.new([%Item{id: path, label: Path.basename(path)}], title: "Files")
    picker_modal(picker, RecentFileSource, nil, "", :ready)
  end

  @spec build_context(term(), EditorState.t()) :: Context.t()
  defp build_context(modal, state \\ TestHelpers.base_state(port_manager: nil)) do
    ctx = Context.from_editor_state(state)
    frame = %{ctx.intent.frame | shell_state: %{modal: modal}}
    %{ctx | intent: %{ctx.intent | frame: frame}}
  end

  @spec temp_file!(binary()) :: String.t()
  defp temp_file!(content) do
    path = Path.join(System.tmp_dir!(), "minga-picker-#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
