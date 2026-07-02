defmodule MingaEditor.RenderPipeline.InputLaunchpadTest do
  @moduledoc """
  Regression pin for the async-render launchpad omission (#2689 follow-up).

  Production rendering snapshots editor state into `RenderPipeline.Input`
  (a plain workspace map with an explicit field list) before the emit
  context is built. The launchpad field was missing from that snapshot, so
  every real frame rendered the launchpad hidden while sync-path tests
  stayed green. These tests drive the exact production layering
  (state -> Input -> Emit.Context -> UI builder -> encoder) and pin the
  snapshot field list against `Session.State` so the next new field must
  be explicitly triaged instead of silently dropped.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Config.Options
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EmptyStateEncoder
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.Builder
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Startup

  @op_gui_empty_state Minga.Protocol.Opcodes.gui_empty_state()

  # Session.State fields deliberately NOT carried by the async render
  # snapshot. A new workspace field must land here or in
  # `Input.from_editor_state/1`'s workspace map; being in neither means it
  # silently disappears on the async render path (the #2689 launchpad bug).
  @snapshot_excluded_fields [
    :dired,
    :lsp_pending,
    :injection_ranges,
    :feature_state,
    :cmd_hover_cell
  ]

  test "the async render snapshot triages every Session.State field", %{tmp_dir: tmp} do
    input = tmp |> boot_state(nil) |> Input.from_editor_state()

    workspace_fields =
      SessionState.__struct__() |> Map.delete(:__struct__) |> Map.keys() |> Enum.sort()

    accounted_fields =
      (Map.keys(input.workspace) ++ @snapshot_excluded_fields) |> Enum.sort()

    assert accounted_fields == workspace_fields
  end

  test "a bufferless boot emits a visible launchpad through the async render snapshot", %{
    tmp_dir: tmp
  } do
    input = tmp |> boot_state(nil) |> Input.from_editor_state()
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

    input = tmp |> boot_state(buffer) |> Input.from_editor_state()
    assert input.workspace.launchpad == nil

    ctx = Context.from_editor_state(input)
    {ui, _ctx} = Builder.build_ui(ctx)

    refute ui.empty_state.visible?
  end

  @spec boot_state(String.t(), pid() | nil) :: MingaEditor.State.t()
  defp boot_state(tmp, buffer) do
    {:ok, options} = Options.start_link(name: nil)

    Startup.build_initial_state(
      port_manager: nil,
      options_server: options,
      buffer: buffer,
      width: 80,
      height: 24,
      editing_model: :vim,
      session_dir: Path.join(tmp, "sessions")
    )
  end
end
