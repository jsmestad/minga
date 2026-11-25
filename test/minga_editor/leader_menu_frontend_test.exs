defmodule MingaEditor.LeaderMenuFrontendTest do
  @moduledoc """
  A native GUI frontend gets the leader keymap for its menu bar as soon as it connects (#4044, AC 4).

  The menu bar's tests each prove one hop: this one proves the editor builds a non-empty menu for a GUI frontend, `gui_protocol_test.exs` round-trips it through the Swift decoder, and the Swift `CommandDispatcher` and `LeaderMenu` tests carry it into the `NSMenu`.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer
  alias Minga.Config.Options
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.RenderPipeline.FrameIntent

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

  @tag :tmp_dir
  test "the native menu follows the active filetype and an in-place language change", %{
    tmp_dir: dir
  } do
    elixir = Path.join(dir, "which_key_menu.ex")
    text = Path.join(dir, "which_key_menu.txt")
    File.write!(elixir, "defmodule MenuFixture do\nend\n")
    File.write!(text, "text")
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    ctx =
      start_editor(File.read!(elixir),
        file_path: elixir,
        project_root: dir,
        capabilities: @macos,
        options_server: options
      )

    assert %{"m a" => "alternate_file", "m t t" => "test_file"} = filetype_commands(ctx)

    :ok = MingaEditor.open_file(ctx.editor, text)
    assert filetype_commands(ctx) == %{}

    buffer = active_buffer(ctx)
    :ok = Buffer.set_filetype(buffer, :elixir)
    # The buffer publishes its deferred invalidation before answering this barrier.
    :sys.get_state(buffer)
    assert %{"m a" => "alternate_file", "m t t" => "test_file"} = filetype_commands(ctx)
  end

  test "a terminal frontend gets no menu bar" do
    ctx = start_editor("hello")

    assert %{appearance: %{gui_config_state: nil}} = editor_state(ctx)
  end

  defp filetype_commands(ctx) do
    frame = ctx |> editor_state() |> FrameIntent.from_editor_state()

    for %{path: "m " <> _ = path, kind: :command, command: command} <-
          frame.gui_config_state.leader_menu,
        into: %{},
        do: {path, command}
  end
end
