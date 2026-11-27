defmodule MingaEditor.Commands.MingaReviewRangeTest do
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Buffer.EditSource

  test "a reversed Visual line range keeps just those changes and percent rejects the rest" do
    ctx = start_editor("one\ntwo\nthree\nfour\n")
    buffer = active_buffer(ctx)

    for {text, line} <- Enum.with_index(["O", "T", "T", "F"]) do
      source = EditSource.minga("t#{line}", "s")
      assert :ok = Buffer.apply_edit(buffer, line, 0, line, 0, text, source)
    end

    assert :ok = Buffer.move_to(buffer, {0, 0})
    send_keys_sync(ctx, "jjVk:")
    assert editor_mode(ctx) == :command
    assert minibuffer(ctx) =~ ":'<,'>"
    send_keys_sync(ctx, "Minga keep<CR>")
    assert editor_mode(ctx) == :normal
    assert buffer_content(ctx) == "One\nTwo\nThree\nFour\n"

    send_keys_sync(ctx, ":%Minga reject<CR>")
    assert buffer_content(ctx) == "one\nTwo\nThree\nfour\n"
  end

  test "an edit while the Visual command is open cannot retarget the saved line range" do
    ctx = start_editor("one\ntwo\n")
    buffer = active_buffer(ctx)
    assert :ok = Buffer.apply_edit(buffer, 1, 0, 1, 0, "T", EditSource.minga("task", "s"))
    assert :ok = Buffer.move_to(buffer, {0, 0})
    send_keys_sync(ctx, "jV:")
    assert editor_mode(ctx) == :command

    assert :ok = Buffer.insert_text(buffer, "!")
    send_keys_sync(ctx, "Minga keep<CR>")
    assert minibuffer(ctx) =~ "Select the lines again"
    assert {:ok, _, {:minga, "task"}, 1} = Buffer.prepare_review(buffer, :latest)
  end

  test "Visual sort and normal both honor the selected rows instead of the first row" do
    ctx = start_editor("header\npear\napple\nfooter\n")
    send_keys_sync(ctx, "jVj:sort<CR>")
    assert buffer_content(ctx) == "header\napple\npear\nfooter\n"

    assert :ok = Buffer.move_to(active_buffer(ctx), {2, 0})
    send_keys_sync(ctx, "Vk:normal rX<CR>")
    assert buffer_content(ctx) == "header\nXpple\nXear\nfooter\n"
  end
end
