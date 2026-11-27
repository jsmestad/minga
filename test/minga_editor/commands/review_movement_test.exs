defmodule MingaEditor.Commands.ReviewMovementTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  test "counted motions skip contiguous pieces and reach a deletion-only head at EOF" do
    ctx = start_editor("prefix\nabcdef\nmiddle\nTAIL")
    buffer = active_buffer(ctx)
    step = EditSource.minga("first", "resumed")

    edit(buffer, {1, 0}, 2, "AB", step)
    edit(buffer, {2, 1}, 2, "ID", EditSource.minga("second", "edit"))
    edit(buffer, {1, 2}, 2, "CD", step)
    edit(buffer, {3, 0}, 4, "", EditSource.minga("third", "deletion"))
    :ok = Buffer.move_to(buffer, {0, 0})

    send_keys_sync(ctx, "2]h")
    assert buffer_cursor(ctx) == {2, 1}
    send_keys_sync(ctx, "]h")
    assert buffer_cursor(ctx) == {3, 0}
    send_keys_sync(ctx, "2[h")
    assert buffer_cursor(ctx) == {1, 0}
    send_keys_sync(ctx, "[h")
    assert buffer_cursor(ctx) == {1, 0}
  end

  test "separated regions of one unit have separate heads, but keeping the unit removes both" do
    ctx = start_editor("prefix\nabc\nuntouched\na ghi\ntrailing")
    buffer = active_buffer(ctx)
    step = EditSource.minga("first", "separated")
    edit(buffer, {1, 0}, 3, "ABC", step)
    edit(buffer, {3, 2}, 3, "GHI", step)
    :ok = Buffer.move_to(buffer, {0, 0})

    send_keys_sync(ctx, "2]h")
    assert buffer_cursor(ctx) == {3, 2}
    send_keys_sync(ctx, "[h")
    assert buffer_cursor(ctx) == {1, 0}
    send_keys_sync(ctx, ":Minga keep<CR>")
    send_keys_sync(ctx, "]h")
    assert buffer_cursor(ctx) == {1, 0}
    assert buffer_content(ctx) == "prefix\nABC\nuntouched\na GHI\ntrailing"
  end

  test "backward motion visits a deletion anchor before the text region that contains it" do
    ctx = start_editor("prefix\nabcde\ntrailing")
    buffer = active_buffer(ctx)
    edit(buffer, {1, 0}, 5, "ABCDE", EditSource.minga("task", "replace"))
    edit(buffer, {1, 2}, 1, "", EditSource.minga("task", "delete"))
    :ok = Buffer.move_to(buffer, {2, 0})

    send_keys_sync(ctx, "[h")
    assert buffer_cursor(ctx) == {1, 2}
    send_keys_sync(ctx, "[h")
    assert buffer_cursor(ctx) == {1, 0}
  end

  test "a counted decision starts at the cursor and never counts a split unit twice" do
    ctx = start_editor("prefix\nabc\ndef\nghi\njkl")
    buffer = active_buffer(ctx)
    split = EditSource.minga("task", "split")
    edit(buffer, {1, 0}, 3, "ABC", split)
    edit(buffer, {2, 0}, 3, "DEF", split)
    edit(buffer, {3, 0}, 3, "GHI", EditSource.minga("task", "second"))
    edit(buffer, {4, 0}, 3, "JKL", EditSource.minga("task", "third"))
    :ok = Buffer.move_to(buffer, {0, 0})
    assert :empty = Buffer.prepare_review(buffer, {:cursor, 2})

    :ok = Buffer.move_to(buffer, {1, 1})
    assert {:ok, target, {:minga, "task"}, 2} = Buffer.prepare_review(buffer, {:cursor, 2})
    assert :ok = Buffer.decide_review(buffer, target, :keep)
    assert {:ok, {4, 0}} = Buffer.move_to_review_change(buffer, :next, 1)
    assert Buffer.content(buffer) == "prefix\nABC\nDEF\nGHI\nJKL"
  end

  test "counted Keep deduplicates units and dot resolves a fresh target without changing text" do
    ctx = start_editor("abc\ndef\nghi\njkl\nmno\npqr")
    buffer = active_buffer(ctx)

    Enum.each(Enum.with_index(~w(ABC DEF GHI JKL MNO PQR)), fn {text, row} ->
      edit(buffer, {row, 0}, 3, text, EditSource.minga("task", text))
    end)

    :ok = Buffer.move_to(buffer, {0, 0})
    send_keys_sync(ctx, "2<SPC>ay")
    assert :empty = Buffer.prepare_review(buffer, {:at_byte, 4})

    :ok = Buffer.move_to(buffer, {2, 0})
    send_keys_sync(ctx, ".")
    assert :empty = Buffer.prepare_review(buffer, {:at_byte, 12})

    :ok = Buffer.move_to(buffer, {4, 0})
    send_keys_sync(ctx, "1.")
    assert :empty = Buffer.prepare_review(buffer, {:at_byte, 16})
    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:at_byte, 20})
    assert buffer_content(ctx) == "ABC\nDEF\nGHI\nJKL\nMNO\nPQR"
  end

  test "visual Reject selects exact characters, and a failed decision does not replace dot" do
    ctx = start_editor("abc def\nghi\njkl")
    buffer = active_buffer(ctx)
    edit(buffer, {0, 0}, 3, "ABC", EditSource.minga("task", "first"))
    edit(buffer, {0, 4}, 3, "DEF", EditSource.minga("task", "second"))
    edit(buffer, {2, 0}, 3, "JKL", EditSource.minga("task", "third"))
    :ok = Buffer.move_to(buffer, {0, 2})

    send_keys_sync(ctx, "vhh<SPC>ad")
    assert buffer_content(ctx) == "abc DEF\nghi\nJKL"
    assert editor_mode(ctx) == :normal

    :ok = Buffer.move_to(buffer, {1, 0})
    send_keys_sync(ctx, "<SPC>ay")
    :ok = Buffer.move_to(buffer, {2, 0})
    send_keys_sync(ctx, ".")
    assert buffer_content(ctx) == "abc DEF\nghi\njkl"
  end

  test "a document edit while visual review is open invalidates the offered selection" do
    ctx = start_editor("abc def")
    buffer = active_buffer(ctx)
    edit(buffer, {0, 0}, 3, "ABC", EditSource.minga("task", "first"))
    :ok = Buffer.move_to(buffer, {0, 0})
    send_keys_sync(ctx, "vll<SPC>a")

    edit(buffer, {0, 4}, 3, "DEF", EditSource.minga("task", "second"))
    send_keys_sync(ctx, "d")
    assert buffer_content(ctx) == "ABC DEF"
    assert editor_mode(ctx) == :visual
  end

  @tag :tmp_dir
  test "an asynchronous counted Keep does not let dot run before its own receipt", %{
    tmp_dir: root
  } do
    ctx = start_gated_editor(root, "ab cd\nwx yz\n")
    buffer = active_buffer(ctx)
    Events.subscribe(:buffer_review_changed, registry: ctx.events_registry)

    for {row, col, text} <- [{0, 0, "AB"}, {0, 3, "CD"}, {1, 0, "WX"}, {1, 3, "YZ"}] do
      edit(buffer, {row, col}, 2, text, EditSource.minga("task", text))
    end

    :ok = Buffer.move_to(buffer, {0, 0})
    assert :ok = send_keys_async(ctx, "2<SPC>ayj1.")
    assert_receive {:reading_keep, first}, 1_000
    assert buffer_cursor(ctx) == {1, 0}
    assert {:ok, _, _, 2} = Buffer.prepare_review(buffer, {:cursor, 2})
    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:at_byte, 0})

    send(first, :publish)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}
    assert_receive {:reading_keep, second}, 1_000
    assert :empty = Buffer.prepare_review(buffer, {:at_byte, 0})
    assert :empty = Buffer.prepare_review(buffer, {:at_byte, 3})
    assert {:ok, _, _, 2} = Buffer.prepare_review(buffer, {:cursor, 2})

    send(second, :publish)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}
    assert :empty = Buffer.prepare_review(buffer, {:at_byte, 6})
    assert {:ok, _, {:minga, "task"}, 1} = Buffer.prepare_review(buffer, {:at_byte, 9})
    assert buffer_content(ctx) == "AB CD\nWX YZ\n"
  end

  @tag :tmp_dir
  test "Reject cannot overtake an earlier Keep on the same change", %{tmp_dir: root} do
    ctx = start_gated_editor(root, "ab\n")
    buffer = active_buffer(ctx)
    edit(buffer, {0, 0}, 2, "AB", EditSource.minga("task", "review"))
    :ok = Buffer.move_to(buffer, {0, 0})
    Events.subscribe(:buffer_review_changed, registry: ctx.events_registry)

    send_keys_sync(ctx, "<SPC>ay<SPC>ad")
    assert_receive {:reading_keep, observer}, 1_000
    assert Buffer.content(buffer) == "AB\n"
    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, :latest)

    send(observer, :publish)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}
    assert :empty = Buffer.prepare_review(buffer, :latest)
    assert Buffer.content(buffer) == "AB\n"
  end

  @tag :tmp_dir
  test "another file accepts input while Keep is waiting, and keeps its own dot", %{tmp_dir: root} do
    ctx = start_gated_editor(root, "ab\n")
    reviewed = active_buffer(ctx)
    edit(reviewed, {0, 0}, 2, "AB", EditSource.minga("task", "review"))
    :ok = Buffer.move_to(reviewed, {0, 0})
    Events.subscribe(:buffer_review_changed, registry: ctx.events_registry)
    assert :ok = send_keys_async(ctx, "<SPC>ay")
    assert_receive {:reading_keep, observer}, 1_000

    path = Path.expand("other.txt", root)
    File.write!(path, "other\n")
    assert :ok = MingaEditor.open_file(ctx.editor, path)
    other = active_buffer(ctx)
    refute other == reviewed
    send_keys_sync(ctx, "i!<Esc>")
    assert Buffer.content(other) == "!other\n"

    send(observer, :publish)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^reviewed}}
    assert :empty = Buffer.prepare_review(reviewed, :latest)
    send_keys_sync(ctx, ".")
    assert active_buffer(ctx) == other
    assert Buffer.content(other) == "!!other\n"

    edit(other, {0, 2}, 5, "OTHER", EditSource.minga("other", "review"))
    :ok = Buffer.move_to(other, {0, 2})
    send_keys_sync(ctx, "<SPC>ay")
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^other}}
    assert :empty = Buffer.prepare_review(other, :latest)
  end

  @tag :tmp_dir
  test "open-file reactivation runs ready dot before the next new key", %{tmp_dir: root} do
    ctx = start_gated_editor(root, "ab\ncd\nef\n")
    reviewed = active_buffer(ctx)
    Events.subscribe(:buffer_review_changed, registry: ctx.events_registry)

    for {row, text} <- [{0, "AB"}, {1, "CD"}, {2, "EF"}] do
      edit(reviewed, {row, 0}, 2, text, EditSource.minga("task", text))
    end

    :ok = Buffer.move_to(reviewed, {0, 0})
    send_keys_sync(ctx, "<SPC>ayj.")
    assert_receive {:reading_keep, first}, 1_000

    other = Path.join(root, "other.txt")
    File.write!(other, "other\n")
    assert :ok = MingaEditor.open_file(ctx.editor, other)
    send(first, :publish)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^reviewed}}

    wait_until(ctx, &is_nil(&1.interaction.keep_requests))

    assert :ok = MingaEditor.open_file(ctx.editor, Path.join(root, "review.txt"))
    assert_receive {:reading_keep, second}, 1_000
    send_keys_sync(ctx, "j")
    send(second, :publish)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^reviewed}}
    assert :empty = Buffer.prepare_review(reviewed, {:at_byte, 3})
    assert {:ok, _, _, 1} = Buffer.prepare_review(reviewed, {:at_byte, 6})
  end

  @tag :tmp_dir
  test "a successful Visual Keep leaves a newer cursor endpoint selected", %{tmp_dir: root} do
    ctx = start_gated_editor(root, "abc def\n")
    buffer = active_buffer(ctx)
    edit(buffer, {0, 0}, 3, "ABC", EditSource.minga("task", "review"))
    :ok = Buffer.move_to(buffer, {0, 0})

    send_keys_sync(ctx, "v<SPC>ay")
    assert_receive {:reading_keep, observer}, 1_000
    assert editor_mode(ctx) == :visual
    :ok = Buffer.move_to(buffer, {0, 4})
    send(observer, :publish)

    wait_until(ctx, fn state ->
      NoticeWorkflow.message(state) == "Kept 1 Minga change"
    end)

    assert editor_mode(ctx) == :visual
    assert buffer_cursor(ctx) == {0, 4}
    assert :empty = Buffer.prepare_review(buffer, :latest)
  end

  @tag :tmp_dir
  test "deferred Visual Reject uses the submitted endpoint, not a later selection", %{
    tmp_dir: root
  } do
    ctx = start_gated_editor(root, "ab\ncd\nef\n")
    buffer = active_buffer(ctx)
    Events.subscribe(:buffer_changed, registry: ctx.events_registry)

    for {row, text} <- [{0, "AB"}, {2, "EF"}, {1, "CD\nextra"}] do
      edit(buffer, {row, 0}, 2, text, EditSource.minga("task", text))
    end

    :ok = Buffer.move_to(buffer, {0, 0})
    send_keys_sync(ctx, "<SPC>ayjV<SPC>ad")
    assert_receive {:reading_keep, observer}, 1_000
    :ok = Buffer.move_to(buffer, {3, 0})
    send(observer, :publish)

    assert_receive {:minga_event, :buffer_changed,
                    %Events.BufferChangedEvent{buffer: ^buffer, source: {:agent, ^buffer, _}}},
                   1_000

    assert buffer_content(ctx) == "AB\ncd\nEF\n"
    assert editor_mode(ctx) == :visual
    assert buffer_cursor(ctx) == {2, 0}
  end

  test "Vim r records a human replacement without inventing another review head" do
    ctx = start_editor("before\nmiddle\nafter\n")
    buffer = active_buffer(ctx)
    edit(buffer, {1, 0}, 1, "M", EditSource.minga("task", "replace one character"))
    :ok = Buffer.move_to(buffer, {1, 0})
    send_keys_sync(ctx, "rX")
    assert buffer_content(ctx) == "before\nXiddle\nafter\n"
    assert buffer_cursor(ctx) == {1, 0}
    %{review_lease: lease} = Buffer.renderer_consume(buffer)
    assert {:ok, [{:shared, {1, 0}, 1}]} = Buffer.render_review_regions(buffer, lease, [{1, 1}])
  end

  @tag :tmp_dir
  test "deferred Visual Ex Keep retains its line bounds after leaving command mode", %{
    tmp_dir: root
  } do
    ctx = start_gated_editor(root, "ab\ncd\nef\n")
    buffer = active_buffer(ctx)
    Events.subscribe(:buffer_review_changed, registry: ctx.events_registry)

    for {row, text} <- [{0, "AB"}, {1, "CD"}, {2, "EF"}] do
      edit(buffer, {row, 0}, 2, text, EditSource.minga("task", text))
    end

    :ok = Buffer.move_to(buffer, {0, 0})
    send_keys_sync(ctx, "<SPC>ayjV:Minga keep<CR>")
    assert_receive {:reading_keep, first}, 1_000
    assert editor_mode(ctx) == :normal
    :ok = Buffer.move_to(buffer, {2, 0})
    send(first, :publish)

    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}
    assert_receive {:reading_keep, second}, 1_000
    send(second, :publish)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}
    assert :empty = Buffer.prepare_review(buffer, {:at_byte, 3})
    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:at_byte, 6})
  end

  @tag :tmp_dir
  test "an exact modeline click cannot move an earlier held dot to another change", %{
    tmp_dir: root
  } do
    ctx = start_gated_editor(root, "ab\ncd\n")
    buffer = active_buffer(ctx)
    edit(buffer, {0, 0}, 2, "AB", EditSource.minga("task", "first"))
    edit(buffer, {1, 0}, 2, "CD", EditSource.minga("task", "second"))
    :ok = Buffer.move_to(buffer, {0, 0})
    {{0, 0}, {{1, 2}, version, revision, point}} = Buffer.cursor_with_review_position(buffer)
    owner = inspect(buffer) |> String.replace_prefix("#PID", "")

    target =
      "next_minga_change_at:#{active_window_id(ctx)}:#{owner}:#{version}:#{revision}:#{point}"

    send_keys_sync(ctx, "<SPC>ay.")
    assert_receive {:reading_keep, observer}, 1_000
    send_gui_action(ctx, {:execute_command, target})
    assert buffer_cursor(ctx) == {0, 0}
    send(observer, :publish)

    wait_until(ctx, &(NoticeWorkflow.message(&1) == "No pending Minga change at the cursor"))
    assert buffer_cursor(ctx) == {0, 0}
    assert :empty = Buffer.prepare_review(buffer, {:at_byte, 0})
    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:at_byte, 3})
  end

  @tag :tmp_dir
  test "a refused asynchronous Keep leaves dot on the preceding edit", %{tmp_dir: root} do
    ctx = start_gated_editor(root, "zero\nabc\ntrail\n")
    buffer = active_buffer(ctx)
    edit(buffer, {1, 0}, 3, "ABC", EditSource.minga("task", "pending"))
    :ok = Buffer.move_to(buffer, {0, 0})
    send_keys_sync(ctx, "xj")
    assert buffer_cursor(ctx) == {1, 0}

    assert :ok = send_keys_async(ctx, "<SPC>ayj.")
    assert_receive {:reading_keep, observer}, 1_000
    assert buffer_cursor(ctx) == {2, 0}
    assert buffer_content(ctx) == "ero\nABC\ntrail\n"

    edit(buffer, {0, 0}, 1, "E", EditSource.minga("other", "intervening"))
    :ok = Buffer.move_to(buffer, {2, 0})
    Events.subscribe(:buffer_changed, registry: ctx.events_registry)
    send(observer, :publish)

    assert_receive {:minga_event, :buffer_changed,
                    %Events.BufferChangedEvent{buffer: ^buffer, source: :user}},
                   1_000

    assert buffer_content(ctx) == "Ero\nABC\nrail\n"
    assert {:ok, _, {:minga, "task"}, 1} = Buffer.prepare_review(buffer, {:at_byte, 4})
  end

  defp start_gated_editor(root, content) do
    caller = self()
    path = Path.expand("review.txt", root)
    File.write!(path, content)

    observe = fn _path, _dirty? ->
      send(caller, {:reading_keep, self()})

      receive do
        :publish -> :unproven
      after
        5_000 -> exit(:test_gate_not_released)
      end
    end

    start_editor(content, file_path: path, keep_observer: observe)
  end

  defp edit(buffer, position, size, text, source) do
    assert {:ok, _receipt} =
             BufferProcess.replace_byte_range_if_version(
               buffer,
               Buffer.version(buffer),
               position,
               size,
               text,
               source
             )
  end
end
