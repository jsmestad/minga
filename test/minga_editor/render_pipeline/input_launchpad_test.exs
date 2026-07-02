defmodule MingaEditor.RenderPipeline.InputLaunchpadTest do
  @moduledoc """
  Regression pin for the async-render launchpad omission (#2689 follow-up).

  Production rendering snapshots editor state into `RenderPipeline.Input`
  (a plain workspace map with an explicit field list) before the emit
  context is built. The launchpad field was missing from that snapshot, so
  every real frame rendered the launchpad hidden while sync-path tests
  stayed green. This test drives the exact production layering:
  state -> Input -> Emit.Context -> UI builder -> encoder.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Config.Options
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EmptyStateEncoder
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.Builder
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Startup

  @op_gui_empty_state Minga.Protocol.Opcodes.gui_empty_state()

  test "a bufferless boot emits a visible launchpad through the async render snapshot", %{
    tmp_dir: tmp
  } do
    {:ok, options} = Options.start_link(name: nil)

    state =
      Startup.build_initial_state(
        port_manager: nil,
        options_server: options,
        buffer: nil,
        width: 80,
        height: 24,
        editing_model: :vim,
        session_dir: Path.join(tmp, "sessions")
      )

    input = Input.from_editor_state(state)
    assert input.workspace.launchpad != nil

    ctx = Context.from_editor_state(input)
    assert ctx.launchpad != nil

    {ui, _ctx} = Builder.build_ui(ctx)
    assert ui.empty_state.visible?

    {cmd, _caches} = EmptyStateEncoder.encode(ui.empty_state, Caches.new())
    assert <<@op_gui_empty_state, _len::16, 1::8, _rest::binary>> = cmd
  end

  test "a buffer-backed boot emits the launchpad as hidden", %{tmp_dir: tmp} do
    {:ok, buffer} = Minga.Buffer.Process.start_link(content: "hello")
    {:ok, options} = Options.start_link(name: nil)

    state =
      Startup.build_initial_state(
        port_manager: nil,
        options_server: options,
        buffer: buffer,
        width: 80,
        height: 24,
        editing_model: :vim,
        session_dir: Path.join(tmp, "sessions")
      )

    input = Input.from_editor_state(state)
    assert input.workspace.launchpad == nil

    ctx = Context.from_editor_state(input)
    {ui, _ctx} = Builder.build_ui(ctx)

    refute ui.empty_state.visible?
  end
end
