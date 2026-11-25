defmodule MingaEditor.LeaderMenuFrontendTest do
  @moduledoc """
  A native GUI frontend gets the leader keymap for its menu bar as soon as it connects (#4044, AC 4).

  The menu bar's tests each prove one hop: this one proves the editor builds a non-empty menu for a GUI frontend, `gui_protocol_test.exs` round-trips it through the Swift decoder, and the Swift `CommandDispatcher` and `LeaderMenu` tests carry it into the `NSMenu`.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaEditor.Frontend.Capabilities

  @macos %Capabilities{
    frontend_type: :native_gui,
    color_depth: :rgb,
    unicode_width: :unicode_15,
    image_support: :none,
    float_support: :native,
    text_rendering: :proportional,
    semantic_ui: true
  }

  test "a GUI frontend gets the leader groups for its menu bar when it connects" do
    # A GUI frontend applies its defaults (absolute line numbers, line spacing) to the options server, so the editor
    # gets a private one: the shared server would change other tests' screens.
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))
    ctx = start_editor("hello", capabilities: @macos, options_server: options)

    %{appearance: %{gui_config_state: config}} = editor_state(ctx)

    groups =
      for %{kind: :group, path: path, label: label} <- config.leader_menu,
          into: %{},
          do: {path, label}

    assert length(config.leader_menu) > 50
    assert groups["s"] == "Search"
    assert groups["c"] == "Code"
    assert groups["f"] == "Files"
  end

  test "a terminal frontend gets no menu bar" do
    ctx = start_editor("hello")

    assert %{appearance: %{gui_config_state: nil}} = editor_state(ctx)
  end
end
