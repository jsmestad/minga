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

    # The keys typed next walk the leader the pill opened.
    send_keys_sync(ctx, "f")
    assert shown_path(ctx) == "SPC f"
    assert buffer_content(ctx) == "hello"
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

  test "in Insert mode the mode pill opens which-key, and the keys typed next walk it instead of typing" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "i")

    send_gui_action(ctx, {:execute_command, "which_key_open"})
    assert shown_path(ctx) == "SPC"

    send_keys_sync(ctx, "f")
    assert shown_path(ctx) == "SPC f"
    send_keys_sync(ctx, "<Esc>")

    assert shown_path(ctx) == nil
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

  test "on the : line, the mode pill lists its keys and a typed key goes to the line and closes them" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, ":")

    send_gui_action(ctx, {:execute_command, "which_key_open"})
    assert shown_path(ctx) == "Command line"

    send_keys_sync(ctx, "w")
    assert shown_path(ctx) == nil
    assert editor_mode(ctx) == :command
    assert minibuffer(ctx) =~ ":w"
  end

  test "⌘. in a file runs the stop, as SPC a s does, in Vim Normal mode" do
    ctx = start_editor("hello")
    editor = GenServer.whereis(ctx.editor)
    handler_id = "which-key-cmd-period-#{System.unique_integer([:positive])}"

    # A telemetry handler runs in the process that executes the command, so matching the editor's pid keeps
    # concurrent tests' commands out.
    :ok =
      :telemetry.attach(
        handler_id,
        [:minga, :command, :execute, :start],
        fn _event, _measurements, %{command: command}, {recipient, editor_pid} ->
          if self() == editor_pid, do: send(recipient, {:command_ran, command})
        end,
        {self(), editor}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    send_key_sync(ctx, ?., 0x08)

    assert_received {:command_ran, :agent_abort}
    assert buffer_content(ctx) == "hello"
  end

  # Every mode the pill can be clicked in: it opens the leader in which-key, the key typed next walks it, Escape closes
  # only the panel, and nothing reaches the buffer. An operator waiting for its motion does not survive the pill.
  for {name, keys, mode_after} <- [
        {"Normal", "", :normal},
        {"Insert", "i", :insert},
        {"Visual", "v", :visual},
        {"Visual line", "V", :visual},
        {"Replace", "R", :replace},
        {"Operator-pending", "d", :normal},
        {"Search", "/", :search}
      ] do
    test "in #{name} mode, the mode pill opens the leader and types nothing" do
      ctx = start_editor("hello")
      if unquote(keys) != "", do: send_keys_sync(ctx, unquote(keys))

      send_gui_action(ctx, {:execute_command, "which_key_open"})
      assert shown_path(ctx) == "SPC"

      send_keys_sync(ctx, "f")
      assert shown_path(ctx) == "SPC f"

      send_keys_sync(ctx, "<Esc>")
      assert shown_path(ctx) == nil
      assert editor_mode(ctx) == unquote(mode_after)
      assert buffer_content(ctx) == "hello"
    end
  end

  test "over a completion popup in Insert mode, the mode pill closes the popup and opens the leader" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "A")

    item = %{
      label: "help",
      insert_text: "help",
      filter_text: "help",
      kind: :function,
      detail: "",
      documentation: ""
    }

    completion = Minga.Editing.Completion.new([item], {0, 5})
    payload = MingaEditor.State.ModalOverlay.Completion.new(1, completion: completion)

    # Opening a real popup needs a completion source; the modal it opens is the same one.
    :sys.replace_state(
      ctx.editor,
      &MingaEditor.Shell.Traditional.ModalWorkflow.open(&1, {:completion, payload})
    )

    assert completion_visible?(ctx)

    send_gui_action(ctx, {:execute_command, "which_key_open"})

    refute completion_visible?(ctx)
    assert shown_path(ctx) == "SPC"
    assert buffer_content(ctx) == "hello"
  end

  test "with completion still waiting on its source, the mode pill closes it and opens the leader" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "A")

    # A completion waiting on its source is the completion modal with no items yet.
    payload = MingaEditor.State.ModalOverlay.Completion.new(1, completion: nil)

    :sys.replace_state(
      ctx.editor,
      &MingaEditor.Shell.Traditional.ModalWorkflow.open(&1, {:completion, payload})
    )

    send_gui_action(ctx, {:execute_command, "which_key_open"})

    assert Runtime.state(editor_state(ctx).shell_runtime).modal == :none
    assert shown_path(ctx) == "SPC"
  end

  test "a macro that cancelled an operator with the mode pill replays the cancel" do
    ctx = start_editor("one\ntwo\nthree")
    send_keys_sync(ctx, "qad")
    send_gui_action(ctx, {:execute_command, "which_key_open"})
    send_keys_sync(ctx, "<Esc>jq")
    assert buffer_content(ctx) == "one\ntwo\nthree"

    send_keys_sync(ctx, "gg@a")

    # Without the recorded cancel, the replay would run `dj` and delete two lines.
    assert buffer_content(ctx) == "one\ntwo\nthree"
  end

  @tag :tmp_dir
  test "SPC m from the mode pill opens the buffer's filetype keys", %{tmp_dir: dir} do
    path = Path.join(dir, "demo.ex")
    File.write!(path, "defmodule Demo do\nend\n")
    ctx = start_editor("defmodule Demo do\nend\n", file_path: path, project_root: dir)

    send_gui_action(ctx, {:execute_command, "which_key_open"})
    send_keys_sync(ctx, "m")

    assert shown_path(ctx) == "SPC m"
    assert map_size(whichkey(ctx).node.children) > 0
  end

  defp whichkey_labels(ctx) do
    whichkey(ctx)
    |> then(&%{&1 | show: true})
    |> MingaEditor.RenderModel.UI.WhichKeyBuilder.build()
    |> Map.fetch!(:entries)
    |> Enum.map(& &1.label)
  end
end
