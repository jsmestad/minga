defmodule MingaEditor.Extension.SidebarGUIEmitTest do
  # Uses the default named sidebar registry read by GUI emit.
  use ExUnit.Case, async: false

  alias Minga.Project.FileTree
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Emit.GUI, as: EmitGUI
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.StatusBar.Data, as: StatusBarData

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    reset_default_sidebar_table()
    on_exit(&reset_default_sidebar_table/0)
    :ok
  end

  test "registered active sidebars own the GUI active id over legacy file tree metadata" do
    root = Path.join(System.tmp_dir!(), "sidebar-gui-emit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.ex"), "")

    file_tree = FileTreeState.open(%FileTreeState{}, FileTree.new(root, width: 32), nil)
    state = gui_state() |> EditorState.set_file_tree(file_tree)
    FileTreeFeature.sync_sidebar(%FileTreeState{})

    assert :ok =
             Sidebar.register({:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               priority: 40,
               preferred_width: 32,
               visible?: true,
               focused?: true,
               semantic_kind: "generic_tree",
               icon: "list.bullet"
             })

    {_ctx, _caches, cmds} = sync_chrome(state)
    payload = gui_sidebars_payload!(cmds)
    assert {"outline", rest} = take_string16(binary_part(payload, 3, byte_size(payload) - 3))

    {id, rest} = take_string16(rest)
    {_display_name, rest} = take_string16(rest)
    {_kind, rest} = take_string16(rest)
    {_icon, rest} = take_string16(rest)
    <<_order::16, flags::8, _preferred_width::16, _badge::16, _rest::binary>> = rest

    assert id == "file_tree"
    refute Bitwise.band(flags, 0x01) != 0
  end

  test "GUI emit includes registered sidebar metadata and skips selection-only snapshot changes" do
    state = gui_state()

    assert :ok =
             Sidebar.register({:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               priority: 40,
               preferred_width: 32,
               visible?: true,
               focused?: true,
               semantic_kind: "generic_tree",
               icon: "list.bullet",
               snapshot: [
                 rows: [%{id: "a", text: "alpha", selected?: true}, %{id: "b", text: "beta"}]
               ]
             })

    {_ctx, caches, first_cmds} = sync_chrome(state)
    assert Enum.any?(first_cmds, &match?(<<0x9F, _::binary>>, &1))

    assert :ok =
             Sidebar.publish_snapshot({:extension, :outline}, "outline",
               rows: [%{id: "a", text: "alpha"}, %{id: "b", text: "beta", selected?: true}]
             )

    {_ctx, _caches, second_cmds} = sync_chrome(state, caches)
    refute Enum.any?(second_cmds, &match?(<<0x9F, _::binary>>, &1))
  end

  defp sync_chrome(state, caches \\ %Caches{}) do
    {ctx, caches} =
      EmitGUI.sync_swiftui_chrome(
        Context.from_editor_state(state),
        StatusBarData.from_state(state),
        nil,
        caches
      )

    {ctx, caches, collect_port_casts() |> List.flatten()}
  end

  defp gui_sidebars_payload!(cmds) do
    Enum.find_value(cmds, fn
      <<0x9F, payload_len::32, payload::binary-size(payload_len)>> -> payload
      _ -> nil
    end)
  end

  defp take_string16(<<len::16, value::binary-size(len), rest::binary>>), do: {value, rest}

  defp collect_port_casts, do: collect_port_casts([])

  defp collect_port_casts(acc) do
    receive do
      {:"$gen_cast", {:send_commands, cmds}} -> collect_port_casts([cmds | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp reset_default_sidebar_table do
    Sidebar.unregister_source({:extension, :outline})
    Sidebar.unregister_source(:builtin)
  end
end
