defmodule MingaEditor.Input.PlatformKeysTest do
  @moduledoc """
  The macOS platform keys a terminal can deliver: ⌘S saves in every mode and ⌘Z undoes in Normal.

  The macOS app runs both from its menu and never sends the key, so these presses are what a terminal with the Kitty keyboard protocol sends.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Config.Options
  alias Minga.Events

  @moduletag :tmp_dir

  @cmd 0x08
  @shift 0x01

  setup do
    options_server = start_supervised!({Options, name: nil})
    assert {:ok, 0} = Options.set(options_server, :auto_save_delay_ms, 0)
    %{options_server: options_server}
  end

  describe "⌘S" do
    for {profile, mode_keys, mode} <- [
          {:vim, "", "Normal"},
          {:vim, "i", "Insert"},
          {:vim, "v", "Visual"},
          {:cua, "", "the CUA profile"}
        ] do
      test "saves the file once in #{mode}", %{tmp_dir: root, options_server: options_server} do
        path = Path.join(root, "saved.txt")
        File.write!(path, "original")

        ctx =
          start_editor("original",
            file_path: path,
            options_server: options_server,
            editing_model: unquote(profile)
          )

        Events.subscribe(:buffer_saved, ctx.events_registry)
        assert :ok = Buffer.insert_text(ctx.buffer, "local ")
        send_keys_sync(ctx, unquote(mode_keys))

        send_key_sync(ctx, ?s, @cmd)

        assert_receive {:minga_event, :buffer_saved, %Events.BufferEvent{path: ^path}}
        assert File.read!(path) == "local original"
        refute Buffer.dirty?(ctx.buffer)

        # One press is one save: in the CUA profile the Editor scope binds ⌘S too, and only one of the two may run.
        :sys.get_state(ctx.editor)
        refute_received {:minga_event, :buffer_saved, _event}
      end
    end

    test "with Shift is not save", %{tmp_dir: root, options_server: options_server} do
      path = Path.join(root, "unsaved.txt")
      File.write!(path, "original")
      ctx = start_editor("original", file_path: path, options_server: options_server)
      assert :ok = Buffer.insert_text(ctx.buffer, "local ")

      send_key_sync(ctx, ?s, @cmd + @shift)

      assert File.read!(path) == "original"
      assert Buffer.dirty?(ctx.buffer)
    end
  end

  describe "⌘Z" do
    test "undoes the last change in Normal, as u does" do
      ctx = start_editor("one two")
      send_keys_sync(ctx, "x")
      assert buffer_content(ctx) == "ne two"

      send_key_sync(ctx, ?z, @cmd)

      assert buffer_content(ctx) == "one two"
    end

    test "types nothing in Insert" do
      ctx = start_editor("one")
      send_keys_sync(ctx, "i")

      send_key_sync(ctx, ?z, @cmd)

      assert buffer_content(ctx) == "one"
      assert editor_mode(ctx) == :insert
    end
  end
end
