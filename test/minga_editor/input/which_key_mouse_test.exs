defmodule MingaEditor.Input.WhichKeyMouseTest do
  @moduledoc """
  Which-key by mouse: the mode pill opens it at once, a row presses its key, the breadcrumb goes back up, and inside a picker it lists the picker's keys (docs/design/surfaces.md, Mouse).

  The frontends send these as `gui_action`s; the BEAM checks each against the open panel's path, so a click on a panel that has changed does nothing.
  """

  use Minga.Test.EditorCase, async: true

  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State.WhichKey

  defp whichkey(ctx), do: Runtime.state(editor_state(ctx).shell_runtime).whichkey
  defp shown_path(ctx), do: WhichKey.path(whichkey(ctx))

  test "the mode pill opens top-level which-key at once, without waiting for the pause" do
    ctx = start_editor("hello")

    send_gui_action(ctx, {:execute_command, "which_key_open"})

    assert shown_path(ctx) == "SPC"
    assert Minga.Editing.in_leader?(editor_state(ctx))
  end

  test "a row presses its key, the breadcrumb goes back up, and a stale click does nothing" do
    ctx = start_editor("hello")
    send_gui_action(ctx, {:execute_command, "which_key_open"})

    send_gui_action(ctx, {:which_key_press, "SPC", ?a, 0})
    assert shown_path(ctx) == "SPC a"

    # A row from the SPC panel, clicked after the panel moved on: nothing happens.
    send_gui_action(ctx, {:which_key_press, "SPC", ?f, 0})
    assert shown_path(ctx) == "SPC a"

    send_gui_action(ctx, {:which_key_press, "SPC a", ?q, 0})
    assert shown_path(ctx) == "SPC a q"

    send_gui_action(ctx, {:which_key_back, "SPC"})
    assert shown_path(ctx) == "SPC"
    assert buffer_content(ctx) == "hello"
  end

  test "a command row runs its command and closes which-key" do
    ctx = start_editor("hello")
    send_gui_action(ctx, {:execute_command, "which_key_open"})

    send_gui_action(ctx, {:which_key_press, "SPC", ?f, 0})
    send_gui_action(ctx, {:which_key_press, "SPC f", ?f, 0})

    assert picker_open?(ctx)
    assert shown_path(ctx) == nil
  end

  test "the mode pill in Insert mode returns to Normal and opens which-key" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "i")

    send_gui_action(ctx, {:execute_command, "which_key_open"})

    assert editor_mode(ctx) == :normal
    assert shown_path(ctx) == "SPC"
    assert buffer_content(ctx) == "hello"
  end

  test "inside a picker, the mode pill lists the picker's keys; a row runs one and esc only closes which-key" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "<SPC>ff")
    assert picker_open?(ctx)

    send_gui_action(ctx, {:execute_command, "which_key_open"})
    assert shown_path(ctx) == "Picker"

    labels = whichkey_labels(ctx)
    for label <- ["Next", "Previous", "Open the selection", "Close"], do: assert(label in labels)

    send_keys_sync(ctx, "<Esc>")
    assert shown_path(ctx) == nil
    assert picker_open?(ctx)

    send_gui_action(ctx, {:execute_command, "which_key_open"})
    send_gui_action(ctx, {:which_key_press, "Picker", 27, 0})
    assert shown_path(ctx) == nil
    refute picker_open?(ctx)
  end

  test "with SPC already pending, the mode pill opens the top level instead of running SPC SPC" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "<SPC>")

    send_gui_action(ctx, {:execute_command, "which_key_open"})

    assert shown_path(ctx) == "SPC"
    refute picker_open?(ctx)
  end

  test "with r or f waiting for its target, the mode pill opens which-key and changes nothing" do
    for pending <- ["r", "f"] do
      ctx = start_editor("hello world")
      send_keys_sync(ctx, pending)

      send_gui_action(ctx, {:execute_command, "which_key_open"})

      assert shown_path(ctx) == "SPC"
      assert buffer_content(ctx) == "hello world"
      assert buffer_cursor(ctx) == {0, 0}
    end
  end

  test "over a picker, a typed key goes to the picker and closes the picker's keys" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "<SPC>ff")
    send_gui_action(ctx, {:execute_command, "which_key_open"})
    assert shown_path(ctx) == "Picker"

    send_keys_sync(ctx, "x")

    assert shown_path(ctx) == nil
    assert picker_open?(ctx)
    assert String.ends_with?(picker_state(ctx).query, "x")
  end

  test "when its picker closes without a key, the picker's keys close with it" do
    ctx = start_editor("hello")
    send_gui_action(ctx, {:execute_command, "buffer_list"})
    send_gui_action(ctx, {:execute_command, "which_key_open"})
    assert shown_path(ctx) == "Picker"

    # A click on a picker row picks it with no key press, so only the modal closing can close the panel.
    {:picker, %{picker_ui: picker_ui}} = Runtime.state(editor_state(ctx).shell_runtime).modal
    {activation_id, _index, _item} = hd(picker_ui.activation_offer.items)

    send_gui_action(
      ctx,
      {:picker_item_activate, picker_ui.activation_offer.generation, activation_id}
    )

    refute picker_open?(ctx)
    assert shown_path(ctx) == nil
  end

  defp whichkey_labels(ctx) do
    whichkey(ctx)
    |> then(&%{&1 | show: true})
    |> MingaEditor.RenderModel.UI.WhichKeyBuilder.build()
    |> Map.fetch!(:entries)
    |> Enum.map(& &1.label)
  end
end
