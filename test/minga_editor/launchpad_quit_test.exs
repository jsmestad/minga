defmodule MingaEditor.LaunchpadQuitTest do
  @moduledoc """
  Quit semantics around the launchpad (#2689): the `quit_last_tab` option
  and `:q` from the empty state.
  """
  # Mutates Application env (:shutdown_fn), so these cannot run async.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor.State, as: EditorState

  @sync_timeout 30_000

  setup do
    previous_shutdown_fn = Application.fetch_env(:minga, :shutdown_fn)
    test_pid = self()

    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :shutdown_fn, fn status ->
      send(test_pid, {:shutdown_called, status})
    end)

    on_exit(fn ->
      case previous_shutdown_fn do
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        {:ok, shutdown_fn} -> Application.put_env(:minga, :shutdown_fn, shutdown_fn)
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        :error -> Application.delete_env(:minga, :shutdown_fn)
      end
    end)
  end

  test ":q on the last tab exits by default (after confirmation)", %{tmp_dir: tmp} do
    {editor, _options} = start_editor("hello", tmp)

    type_string(editor, ":q\r")
    state = sync(editor)
    assert state.pending_quit == :quit

    type_string(editor, "y")
    assert_receive {:shutdown_called, 0}
  end

  test ":q on the last tab closes into the launchpad with quit_last_tab: :empty_state", %{
    tmp_dir: tmp
  } do
    {editor, options} = start_editor("hello", tmp)
    assert {:ok, :empty_state} = Options.set(options, :quit_last_tab, :empty_state)

    type_string(editor, ":q\r")
    state = sync(editor)

    refute_receive {:shutdown_called, _}, 50
    assert state.workspace.buffers.list == []
    assert state.workspace.launchpad != nil
    assert EditorState.active_window_struct(state).content == {:empty, :semantic}
  end

  test ":q from the launchpad quits the editor", %{tmp_dir: tmp} do
    {editor, _options} = start_empty_editor(tmp)

    type_string(editor, ":q\r")
    state = sync(editor)
    assert state.pending_quit == :quit

    type_string(editor, "y")
    assert_receive {:shutdown_called, 0}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp start_editor(content, tmp) do
    {:ok, buffer} = BufferProcess.start_link(content: content)
    start_editor_with_buffer(buffer, tmp)
  end

  defp start_empty_editor(tmp), do: start_editor_with_buffer(nil, tmp)

  defp start_editor_with_buffer(buffer, tmp) do
    {:ok, options} = Options.start_link(name: nil)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"launchpad_quit_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        options_server: options,
        buffer: buffer,
        width: 60,
        height: 20,
        editing_model: :vim,
        session_dir: Path.join(tmp, "quit-sessions")
      )

    {editor, options}
  end

  defp type_string(editor, text) do
    text
    |> String.to_charlist()
    |> Enum.each(&send(editor, {:minga_input, {:key_press, &1, 0}}))

    sync(editor)
  end

  defp sync(editor), do: :sys.get_state(editor, @sync_timeout)
end
