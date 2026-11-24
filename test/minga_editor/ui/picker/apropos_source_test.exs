defmodule MingaEditor.UI.Picker.AproposSourceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.UI.Picker.AproposSource
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.EditPublicationSource

  defp build_context do
    buf = start_supervised!({BufferProcess, content: "", buffer_name: "test.txt"})
    {:ok, keymap} = ActiveKeymap.start_link(name: nil)
    {:ok, options} = Minga.Config.Options.start_link(name: nil)

    Context.from_editor_state(%EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      interaction: %MingaEditor.State.Interaction{keymap_server: keymap, options_server: options},
      workspace: %MingaEditor.Session.State{buffers: %Buffers{active: buf, list: [buf]}}
    })
  end

  test "SPC h a searches commands and options in one list, grouped by kind" do
    candidates = AproposSource.candidates(build_context())

    assert Enum.any?(candidates, &match?(%{id: {:command, :save}, group: "Commands"}, &1))
    assert Enum.any?(candidates, &match?(%{id: {:option, :tab_width}, group: "Options"}, &1))

    groups = candidates |> Enum.map(& &1.group) |> Enum.dedup()
    assert groups == ["Commands", "Options"]
  end

  test "SPC a p offers publish and discard in one prompt" do
    assert ["Publish", "Discard"] =
             Enum.map(EditPublicationSource.candidates(build_context()), & &1.label)
  end
end
