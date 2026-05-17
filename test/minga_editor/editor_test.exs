defmodule MingaEditor.EditorTest do
  @moduledoc """
  Smoke tests for the Editor GenServer contracts that are not covered by command or render-pipeline tests.
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor
  alias MingaEditor.Startup

  describe "build_initial_state/1" do
    test "returns normal-mode state with the provided buffer active" do
      {:ok, buffer} = BufferProcess.start_link(content: "hi")

      state =
        Startup.build_initial_state(
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      assert Minga.Editing.mode(state) == :normal
      assert active_buffer_pid(state) == buffer
    end

    test "creates a default buffer when none is provided" do
      state =
        Startup.build_initial_state(
          port_manager: nil,
          buffer: nil,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      assert Minga.Editing.mode(state) == :normal
      assert is_pid(active_buffer_pid(state))
    end
  end

  describe "open_file/2" do
    @tag :tmp_dir
    test "opens a file and switches active content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test_open.txt")
      File.write!(path, "opened file content")
      options_server = start_supervised!({Options, name: nil})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :text, :autopair_block, false)

      ctx = start_editor("scratch", options_server: options_server)

      assert :ok = MingaEditor.open_file(ctx.editor, path)
      editor_state(ctx)

      assert active_content(ctx) == "opened file content"
      refute BufferProcess.get_option(active_buffer(ctx), :autopair_block)
    end
  end

  describe "message handling" do
    test "render and stray messages do not crash the editor" do
      ctx = start_editor("hello")
      ref = Process.monitor(ctx.editor)

      MingaEditor.render(ctx.editor)
      send(ctx.editor, :some_random_message)
      send(ctx.editor, {:unexpected, :tuple})
      editor_state(ctx)

      refute_received {:DOWN, ^ref, :process, _, _}
    end
  end

  describe "read-only buffers" do
    test "pressing i on a read-only buffer surfaces the warning" do
      buffer = start_supervised!({BufferProcess, content: "read only", read_only: true})
      ctx = start_editor_with_buffer(buffer)

      send_key_sync(ctx, ?i)
      sync_screen(ctx)

      assert_minibuffer_contains(ctx, "Buffer is read-only")
      assert editor_mode(ctx) == :normal
    end
  end

  defp active_buffer_pid(state), do: state.workspace.buffers.active
end
