defmodule MingaEditor.UnsavedTextListTest do
  @moduledoc """
  `SPC q u` lists unsaved text that no start recovers by itself. A row can be recovered into a buffer for its file, or discarded after a confirmation.
  """

  # The list decides which swap owners are gone with the real check, which runs `ps`.
  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Session.Swap

  @moduletag :tmp_dir
  @moduletag capture_log: true

  # No process has this id, so a swap written under it belongs to an editor that is gone.
  @dead_editor 99_999_999

  setup %{tmp_dir: dir} do
    other = Path.join(dir, "other_project")
    File.mkdir_p!(Path.join(other, "lib"))
    File.write!(Path.join(other, "mix.exs"), "")
    file = Path.join(other, "lib/notes.ex")
    File.write!(file, "saved\n")
    swap_dir = Path.join(dir, "swap")

    %{notes: file, gone: Path.join(other, "lib/deleted_dir/gone.ex"), swap_dir: swap_dir}
  end

  test "the list shows what is waiting, and a row is recovered into a buffer for its file", ctx do
    swap = leftover_swap(ctx, ctx.notes, "unsaved in another project\n")
    editor = start_editor("scratch", swap_dir: ctx.swap_dir)

    open_list(editor)

    assert [%{label: "lib/notes.ex", description: "1 line differs · just now"} = row] =
             rows(editor)

    assert String.starts_with?(row.group, "other_project · ")

    send_keys_sync(editor, "<CR>")

    {:ok, buffer} = Buffer.pid_for_path(ctx.notes)
    on_exit(fn -> DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, buffer) end)
    assert Buffer.content(buffer) == "unsaved in another project\n"
    assert Buffer.dirty?(buffer)
    assert active_buffer(editor) == buffer
    assert notice_message(editor) =~ "Recovered the unsaved text of notes.ex"
    # The buffer holds the text now, so the swap it came from is gone and the list is empty.
    refute File.exists?(swap)
    assert File.read!(ctx.notes) == "saved\n"

    open_list(editor)
    assert rows(editor) == []
    assert %{title: "No unsaved text is waiting."} = picker_state(editor).empty
  end

  test "text whose file and directory are gone is recovered into a buffer for that path", ctx do
    leftover_swap(ctx, ctx.gone, "typed for an hour\n")
    editor = start_editor("scratch", swap_dir: ctx.swap_dir)

    open_list(editor)
    assert [%{description: "1 line, the file is gone · just now"}] = rows(editor)
    send_keys_sync(editor, "<CR>")

    {:ok, buffer} = Buffer.pid_for_path(ctx.gone)
    on_exit(fn -> DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, buffer) end)
    assert Buffer.file_path(buffer) == ctx.gone
    assert Buffer.content(buffer) == "typed for an hour\n"
    assert active_buffer(editor) == buffer
  end

  test "discard asks first, says what goes, and deletes only on yes", ctx do
    swap = leftover_swap(ctx, ctx.notes, "one\ntwo\n")
    editor = start_editor("scratch", swap_dir: ctx.swap_dir)

    open_list(editor)
    choose_discard(editor)

    assert prompt_label(editor) ==
             "Delete the unsaved text of notes.ex (2 lines)? It cannot be undone. (y/n): "

    # Anything but yes keeps the text.
    send_keys_sync(editor, "n<CR>")
    assert notice_message(editor) == "Kept the unsaved text of notes.ex"
    assert File.exists?(swap)

    open_list(editor)
    choose_discard(editor)
    send_keys_sync(editor, "y<CR>")

    assert notice_message(editor) == "Deleted the unsaved text of notes.ex"
    refute File.exists?(swap)
    assert Buffer.pid_for_path(ctx.notes) == :not_found
    assert File.read!(ctx.notes) == "saved\n"
  end

  test "discarding text that another editor took meanwhile says so instead of \"deleted\"", ctx do
    swap = leftover_swap(ctx, ctx.notes, "one\ntwo\n")
    editor = start_editor("scratch", swap_dir: ctx.swap_dir)

    open_list(editor)
    choose_discard(editor)
    # Another editor recovers the text while the prompt is open: its buffer owns it now.
    File.rm!(swap)
    send_keys_sync(editor, "y<CR>")

    assert notice_message(editor) == "The unsaved text of notes.ex is no longer waiting"
  end

  test "recovering text that another editor took meanwhile says so instead of \"kept\"", ctx do
    swap = leftover_swap(ctx, ctx.notes, "one\ntwo\n")
    editor = start_editor("scratch", swap_dir: ctx.swap_dir)

    open_list(editor)
    # Another editor recovers the text while the list is open: its buffer owns it now.
    File.rm!(swap)
    send_keys_sync(editor, "<CR>")

    assert notice_message(editor) == "The unsaved text of notes.ex is no longer waiting"
    assert Buffer.pid_for_path(ctx.notes) == :not_found
  end

  test "an editor that keeps no swap files shows an empty list instead of failing" do
    editor = start_editor("scratch")

    open_list(editor)

    assert rows(editor) == []

    assert %{title: "No unsaved text is waiting.", why: "Text kept after a crash shows up here."} =
             picker_state(editor).empty

    # Nothing to filter and nothing to run: the list takes no text, and q closes it.
    send_keys_sync(editor, "x")
    assert picker_state(editor).query == ""
    send_keys_sync(editor, "q")
    refute picker_open?(editor)
  end

  test "a file with unsaved changes of its own keeps them, and the waiting text stays", ctx do
    swap = leftover_swap(ctx, ctx.notes, "from before the crash\n")
    editor = start_editor("scratch", swap_dir: ctx.swap_dir)
    {:ok, buffer} = Buffer.ensure_for_path(ctx.notes)
    on_exit(fn -> DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, buffer) end)
    :ok = Buffer.replace_content(buffer, "typed since\n")

    open_list(editor)
    send_keys_sync(editor, "<CR>")

    assert Buffer.content(buffer) == "typed since\n"
    assert File.exists?(swap)
    assert notice_message(editor) =~ "notes.ex has unsaved changes of its own"
  end

  defp open_list(editor) do
    send_keys_sync(editor, "<SPC>qu")

    wait_until(editor, fn _state -> loaded?(picker_state(editor)) end,
      max_attempts: 200,
      message: "the list of waiting unsaved text did not load"
    )
  end

  # The list has loaded when it shows rows, or says that nothing is waiting.
  defp loaded?(nil), do: false
  defp loaded?(picker), do: picker.filtered != [] or not is_nil(picker.empty)

  defp rows(editor) do
    case picker_state(editor) do
      nil -> []
      picker -> picker.filtered
    end
  end

  # The act menu lists Recover first and Discard second.
  defp choose_discard(editor), do: send_keys_sync(editor, "<C-.><C-j><CR>")

  defp prompt_label(editor) do
    case editor_state(editor).shell_runtime.state.modal do
      {:prompt, %{prompt_ui: %{label: label}}} -> label
      other -> flunk("expected a prompt, got #{inspect(other, limit: 3)}")
    end
  end

  # Writes the swap that a killed editor left for the file.
  defp leftover_swap(ctx, path, content) do
    opts = [swap_dir: ctx.swap_dir, os_pid: @dead_editor]
    {:ok, prepared} = Swap.prepare(path, content, opts)
    :ok = Swap.publish(prepared)
    Swap.swap_path(path, opts)
  end
end
