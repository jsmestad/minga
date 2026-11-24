defmodule MingaEditor.Input.PromptKeysWiringTest do
  @moduledoc """
  Wiring for the keys `docs/design/keys.md` declares for live prompts: they reach the `:picker` and `:prompt` keymap scopes through the real input path.

  The key rules are covered by `Minga.Keymap.PromptKeysTest`, `Minga.Editing.LineEditTest`, `MingaEditor.PickerUITest`, `MingaEditor.PromptUITest` and `Minga.Mode.CommandTest`.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  @moduletag :tmp_dir

  test "the buffer switcher moves with ⌃J and opens the highlighted buffer in a split with ⌃V", %{
    tmp_dir: dir
  } do
    other = Path.join(dir, "other.txt")
    File.write!(other, "other\n")

    ctx = start_editor("origin")
    send_ex_sync(ctx, "e #{other}")

    send_keys_sync(ctx, "<Space>bb")
    assert picker_open?(ctx)

    send_keys_sync(ctx, "<C-j>")
    picker = modal_picker!(ctx).picker_ui.picker
    assert %{id: {:buffer, highlighted}} = MingaEditor.UI.Picker.selected_item(picker)

    send_keys_sync(ctx, "<C-v>")

    refute picker_open?(ctx)
    assert window_count(ctx) == 2
    assert active_window_buffer(ctx) == highlighted
  end

  test "find file edits its query with ⌃W and ⌃U and closes with esc" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "<Space><Space>")
    assert picker_open?(ctx)

    send_keys_sync(ctx, "lib foo")
    assert modal_picker!(ctx).picker_ui.picker.query == "lib foo"

    send_keys_sync(ctx, "<C-w>")
    assert modal_picker!(ctx).picker_ui.picker.query == "lib "

    send_keys_sync(ctx, "<C-a>")
    assert modal_picker!(ctx).picker_ui.picker.query == "lib "

    send_keys_sync(ctx, "<C-u>")
    assert modal_picker!(ctx).picker_ui.picker.query == ""

    send_keys_sync(ctx, "<Esc>")
    refute picker_open?(ctx)
  end

  test "a minibuffer prompt keeps ⌃A and ⌃U as text editing" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "<Space>pa")
    send_keys_sync(ctx, "<C-u>")
    send_keys_sync(ctx, "/tmp/some project")
    send_keys_sync(ctx, "<C-w>")
    send_keys_sync(ctx, "<C-a>x")
    assert minibuffer(ctx) =~ "x/tmp/some "

    send_keys_sync(ctx, "<Esc>")
    refute minibuffer(ctx) =~ "x/tmp/some "
  end

  test "the command line edits with ⌃W and ⌃U, and ⌃H deletes like backspace" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, ":e foo/bar")
    assert editor_mode(ctx) == :command

    send_keys_sync(ctx, "<C-w>")
    assert minibuffer(ctx) =~ ":e "
    refute minibuffer(ctx) =~ "foo"

    send_keys_sync(ctx, "<C-h><C-u>")
    assert editor_mode(ctx) == :command

    send_keys_sync(ctx, "<Esc>")
    assert editor_mode(ctx) == :normal
  end
end
