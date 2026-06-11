defmodule MingaEditor.RuntimeThemePushTest do
  @moduledoc """
  Proves the runtime `:theme` change no longer needs an out-of-band gui_theme push
  (#2119). Applying the theme then invalidating every window and the layout forces
  a re-render whose frame transaction re-emits gui_theme semantically through the
  adapter ThemeEncoder (the new theme changes the adapter cache fingerprint).
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias Minga.Events.OptionChangedEvent
  alias Minga.Protocol.Opcodes
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Theme

  @op_gui_theme Opcodes.gui_theme()

  # This test mutates the :theme option; an isolated options server keeps the
  # mutation out of the global server that concurrent async tests (snapshot
  # suites especially) read their theme from.
  setup do
    id = :erlang.unique_integer([:positive])
    events_registry = :"runtime_theme_events_#{id}"
    start_supervised!({Minga.Events, name: events_registry})

    options_server =
      start_supervised!({Options, name: nil, events_registry: events_registry},
        id: {:runtime_theme_options, id}
      )

    %{isolated_options_server: options_server}
  end

  test "changing the theme at runtime re-emits gui_theme in-frame, no out-of-band push", %{
    isolated_options_server: isolated_options_server
  } do
    gui_caps = %Capabilities{frontend_type: :native_gui}

    {:ok, recorder} =
      RecordingFrontend.start_link(owner: self(), width: 80, height: 24, capabilities: gui_caps)

    ctx =
      start_editor("hello",
        width: 80,
        height: 24,
        capabilities: gui_caps,
        options_server: isolated_options_server
      )

    # Swap the editor's port to the recorder so we capture the runtime-change frame.
    :sys.replace_state(ctx.editor, fn state -> %{state | port_manager: recorder} end)
    RecordingFrontend.reset(recorder)

    state = editor_state(ctx)
    options_server = EditorState.options_server(state)
    current_name = state.theme.name

    # Pick a theme different from the current one so the adapter fingerprint moves.
    target =
      Enum.find(Theme.available(), fn name -> Theme.get!(name).name != current_name end)

    # Drive the real option-change path: the editor's :option_changed handler
    # applies the theme, invalidates windows + layout, and re-renders. No gui_theme
    # is pushed out-of-band anywhere in that path.
    send(
      ctx.editor,
      {:minga_event, :option_changed,
       %OptionChangedEvent{source: options_server, name: :theme, value: target}}
    )

    _ = GenServer.call(ctx.editor, :api_mode, 15_000)

    commands = RecordingFrontend.commands(recorder)
    theme_cmds = Enum.filter(commands, fn <<op, _rest::binary>> -> op == @op_gui_theme end)

    assert theme_cmds != [],
           "runtime theme change must re-emit gui_theme in-frame; opcodes were " <>
             inspect(Enum.map(commands, fn <<op, _::binary>> -> op end))

    # Every emitted gui_theme carries a non-empty color slot table (the new theme).
    assert Enum.all?(theme_cmds, fn <<@op_gui_theme, count::8, _rest::binary>> -> count > 0 end)

    # The editor actually adopted the new theme.
    assert editor_state(ctx).theme.name == Theme.get!(target).name
  end
end
