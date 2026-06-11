defmodule Minga.Integration.GUISettingsActionTest do
  # Exercises the globally registered GUI settings writer, so it must clean the overlay serially.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Frontend.Adapter.GUI.ConfigStateEncoder
  alias Minga.Test.RecordingFrontend
  alias MingaEditor
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.RenderModel.UI.ConfigStateBuilder

  setup do
    gui_settings_path = Minga.Config.Loader.gui_settings_path()
    File.rm(gui_settings_path)

    on_exit(fn ->
      Minga.Config.Writer.flush()
      File.rm(gui_settings_path)
    end)

    :ok
  end

  test "config_query emits full config state in-frame" do
    ctx = start_recording_editor(:gui_settings_query)
    RecordingFrontend.reset(ctx.port)

    send(ctx.editor, {:minga_input, {:gui_action, :config_query}})
    sync_editor(ctx.editor)

    # config_state rides inside the frame transaction now (#2119): the full
    # snapshot is encoded by the adapter ConfigStateEncoder, byte-identical to the
    # legacy out-of-band push, and appears in the emitted command stream.
    expected =
      ProtocolGUI.config_state(ctx.options_server, Minga.Keymap.default_server())
      |> ConfigStateBuilder.from_wire()
      |> ConfigStateEncoder.encode_command()

    assert expected in RecordingFrontend.commands(ctx.port)
  end

  test "config_update applies live changes and emits the updated config state in-frame" do
    ctx = start_recording_editor(:gui_settings_update)
    RecordingFrontend.reset(ctx.port)

    send(ctx.editor, {:minga_input, {:gui_action, {:config_update, :wrap, true}}})
    sync_editor(ctx.editor)

    assert Options.get(ctx.options_server, :wrap) == true
    assert BufferProcess.get_option(ctx.buffer, :wrap) == true

    # The full config snapshot carrying the updated value is emitted in-frame,
    # byte-identical to projecting the current servers and encoding the snapshot.
    expected =
      ProtocolGUI.config_state(ctx.options_server, Minga.Keymap.default_server())
      |> ConfigStateBuilder.from_wire()
      |> ConfigStateEncoder.encode_command()

    assert expected in RecordingFrontend.commands(ctx.port)
  end

  test "config_update persists settings and keeps explicit GUI defaults" do
    ctx = start_recording_editor(:gui_settings_persist)

    send(ctx.editor, {:minga_input, {:gui_action, {:config_update, :wrap, false}}})
    sync_editor(ctx.editor)
    Minga.Config.Writer.flush()

    assert Options.get(ctx.options_server, :wrap) == false
    assert BufferProcess.get_option(ctx.buffer, :wrap) == false
    assert File.read!(Minga.Config.Loader.gui_settings_path()) =~ "set :wrap, false"

    send(ctx.editor, {:minga_input, {:gui_action, {:config_update, :line_numbers, :hybrid}}})
    sync_editor(ctx.editor)

    assert Options.get(ctx.options_server, :line_numbers) == :hybrid
    assert Options.explicitly_set?(ctx.options_server, :line_numbers)

    send(ctx.editor, {:minga_input, {:ready, 80, 24}})
    sync_editor(ctx.editor)

    assert Options.get(ctx.options_server, :line_numbers) == :hybrid
  end

  defp start_recording_editor(suffix) do
    id = System.unique_integer([:positive])
    events_registry = start_events_registry(suffix)

    options_server =
      start_supervised!({Options, name: nil, events_registry: events_registry},
        id: {:options, suffix, id}
      )

    {:ok, buffer} = BufferProcess.start_link(content: "", events_registry: events_registry)

    port =
      start_supervised!(
        {RecordingFrontend,
         owner: self(),
         width: 80,
         height: 24,
         capabilities: %Capabilities{frontend_type: :native_gui}},
        id: {:recording_frontend, suffix, id}
      )

    editor =
      start_supervised!(
        {MingaEditor,
         name: :"#{__MODULE__}.editor.#{id}",
         backend: :headless,
         port_manager: port,
         buffer: buffer,
         width: 80,
         height: 24,
         editing_model: :vim,
         options_server: options_server,
         events_registry: events_registry,
         suppress_tool_prompts: true},
        id: {:editor, suffix, id}
      )

    send(editor, {:minga_input, {:ready, 80, 24}})
    sync_editor(editor)
    drain_frontend_commands(port)

    %{editor: editor, port: port, buffer: buffer, options_server: options_server}
  end

  defp start_events_registry(suffix) do
    name = :"#{__MODULE__}.#{suffix}.#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: name})
    name
  end

  defp sync_editor(editor), do: GenServer.call(editor, :api_mode)

  defp drain_frontend_commands(port) do
    receive do
      {:frontend_commands, ^port, _commands} -> drain_frontend_commands(port)
    after
      0 -> :ok
    end
  end
end
