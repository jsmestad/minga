defmodule MingaEditor.UI.Picker.CommandHelpSourceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.UI.Picker.CommandHelpSource
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.Viewport

  defp build_state do
    {:ok, buf} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {BufferServer, content: "", buffer_name: "test.txt"}
      )

    {:ok, keymap} = ActiveKeymap.start_link(name: nil)
    {:ok, options} = Minga.Config.Options.start_link(name: nil)

    %EditorState{
      port_manager: nil,
      keymap_server: keymap,
      options_server: options,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]}
      }
    }
  end

  defp build_context do
    Context.from_editor_state(build_state())
  end

  describe "title/0" do
    test "returns Describe Command" do
      assert CommandHelpSource.title() == "Describe Command"
    end
  end

  describe "candidates/1" do
    test "returns items for registered commands" do
      candidates = CommandHelpSource.candidates(build_context())

      assert is_list(candidates)
      assert length(candidates) > 0
      assert Enum.all?(candidates, &match?(%Item{}, &1))
    end

    test "items are sorted by label" do
      candidates = CommandHelpSource.candidates(build_context())
      labels = Enum.map(candidates, & &1.label)

      assert labels == Enum.sort(labels)
    end

    test "includes keybinding annotations" do
      candidates = CommandHelpSource.candidates(build_context())
      save_item = Enum.find(candidates, &(&1.id == :save))

      assert save_item != nil
      assert save_item.annotation =~ "SPC f s"
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{foo: :bar}
      assert CommandHelpSource.on_cancel(state) == state
    end
  end
end
