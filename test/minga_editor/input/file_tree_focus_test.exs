defmodule MingaEditor.Input.FileTreeFocusTest do
  @moduledoc """
  Focusing the file tree from a focused Agent composer must leave the composer and Insert mode, whichever path focuses the tree (#3955).
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias Minga.Test.HeadlessPort
  alias MingaEditor.FocusOwner
  alias MingaEditor.Layout

  @moduletag :tmp_dir

  # Each row focuses the tree while the composer holds focus in Insert. The
  # first command opens an unloaded tree, the second reveals a hidden loaded
  # tree, and the sidebar row focuses a visible tree. Rows that need a loaded
  # tree re-enter the composer with a prompt click after loading it.
  @entry_points [
    command_open: :unloaded,
    command_reveal: :hidden,
    sidebar_activate: :visible
  ]

  for {entry, tree} <- @entry_points do
    test "#{entry} focuses a Normal-mode tree that owns SPC f f instead of the draft", %{
      tmp_dir: dir
    } do
      ctx = open_editor(dir)
      send_keys_sync(ctx, "<SPC>aSn")
      composer_in_insert(ctx, unquote(tree))
      draft = agent_chat(ctx).prompt

      focus_tree(ctx, unquote(entry))

      assert editor_mode(ctx) == :normal
      assert %{surface: :file_tree} = FocusOwner.derive(editor_state(ctx))

      send_keys_sync(ctx, "<SPC>ff")

      assert picker_open?(ctx)
      assert %{input_focused?: false, prompt: ^draft} = agent_chat(ctx)
    end
  end

  test "clicking the composer after focusing the tree returns keys to the draft", %{
    tmp_dir: dir
  } do
    ctx = open_editor(dir)
    send_keys_sync(ctx, "<SPC>aSn")
    focus_tree(ctx, :command_open)

    click_prompt(ctx)
    send_keys_sync(ctx, "idraft")

    assert %{input_focused?: true, prompt: "draft"} = agent_chat(ctx)
    assert %{surface: :agent} = FocusOwner.derive(editor_state(ctx))
    assert %{visible?: true, focused?: false} = file_tree(ctx)
  end

  test "SPC w l from the focused tree focuses the composer and SPC w h returns to the tree", %{
    tmp_dir: dir
  } do
    ctx = open_editor(dir)
    send_keys_sync(ctx, "<SPC>aSn")
    focus_tree(ctx, :command_open)
    wait_until_screen(ctx, fn -> match?(%{rows: [_ | _]}, file_tree(ctx)) end)
    assert %{focused?: true} = file_tree(ctx)

    send_keys_sync(ctx, "<SPC>wl")

    assert %{surface: :agent} = FocusOwner.derive(editor_state(ctx))
    assert %{input_focused?: true} = agent_chat(ctx)
    assert %{visible?: true, focused?: false} = file_tree(ctx)

    send_keys_sync(ctx, "<SPC>wh")

    assert %{surface: :file_tree} = FocusOwner.derive(editor_state(ctx))
    assert %{input_focused?: false} = agent_chat(ctx)
    assert %{focused?: true} = file_tree(ctx)
  end

  defp open_editor(dir) do
    path = Path.join(dir, "focus.txt")
    File.write!(path, "focus")
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    start_editor("focus",
      file_path: path,
      project_root: dir,
      shell: :traditional,
      options_server: options,
      agent_provider_module: Minga.Test.StubProvider
    )
  end

  defp composer_in_insert(ctx, :unloaded), do: assert_composer_insert(ctx)

  defp composer_in_insert(ctx, :hidden) do
    composer_in_insert(ctx, :visible)
    send_gui_action(ctx, {:execute_command, "toggle_file_tree"})
    assert_composer_insert(ctx)
  end

  defp composer_in_insert(ctx, :visible) do
    send_gui_action(ctx, {:execute_command, "toggle_file_tree"})
    click_prompt(ctx)

    unless editor_mode(ctx) == :insert, do: send_keys_sync(ctx, "i")
    assert_composer_insert(ctx)
  end

  defp assert_composer_insert(ctx) do
    assert editor_mode(ctx) == :insert
    assert %{input_focused?: true} = agent_chat(ctx)
  end

  defp focus_tree(ctx, command) when command in [:command_open, :command_reveal],
    do: send_gui_action(ctx, {:execute_command, "toggle_file_tree"})

  defp focus_tree(ctx, :sidebar_activate),
    do: send_gui_action(ctx, {:sidebar_action, "file_tree", "file_tree", "activate"})

  # Clicks the last row of the Agent chat window, which is the composer.
  defp click_prompt(ctx) do
    {row, col, width, height} =
      ctx |> editor_state() |> Layout.get() |> active_window_rect()

    send_mouse(
      ctx,
      row + height - 1 + HeadlessPort.editor_row_offset(ctx.port),
      col + div(width, 2),
      :left
    )
  end

  defp active_window_rect(%Layout{window_layouts: layouts}) do
    [%{total: rect}] = Map.values(layouts)
    rect
  end
end
