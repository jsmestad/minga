defmodule MingaEditor.UI.Picker.CommandSourceFrecencyTest do
  @moduledoc "Tests command palette frecency ordering, persistence, and selection recording."

  # Mutates process-global XDG_CONFIG_HOME and the global Minga.Project singleton.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project
  alias MingaEditor.Input.Picker, as: PickerInput
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.CommandSource
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.OptionScopeSource
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Session.State, as: SessionState

  setup %{tmp_dir: tmp_dir} do
    previous_config_home = System.get_env("XDG_CONFIG_HOME")
    config_home = Path.join(tmp_dir, "config")
    File.mkdir_p!(Path.join(config_home, "minga"))
    System.put_env("XDG_CONFIG_HOME", config_home)

    previous_project = :sys.get_state(Project)
    reset_global_command_frecency()

    on_exit(fn ->
      restore_xdg_config_home(previous_config_home)
      restore_global_command_frecency(previous_project.command_frecency)
    end)

    :ok
  end

  test "recent commands are ranked before alphabetical commands" do
    record_global_command(:quit, 5)

    items = CommandSource.candidates(nil)
    quit_index = Enum.find_index(items, &(&1.id == :quit))
    save_index = Enum.find_index(items, &(&1.id == :save))

    assert is_integer(quit_index)
    assert is_integer(save_index)
    assert quit_index < save_index
  end

  test "typed queries still re-rank by fuzzy match after frecency pre-ordering" do
    record_global_command(:quit_all, 5)
    record_global_command(:quit, 1)

    candidates = CommandSource.candidates(nil)
    assert index_of(candidates, :quit_all) < index_of(candidates, :quit)

    picker = Picker.new(candidates, title: CommandSource.title())
    filtered = Picker.filter(picker, "q")

    assert Picker.selected_id(filtered) == :quit
  end

  test "persisted command frecency reloads from the XDG config path" do
    file = command_frecency_path()
    File.rm(file)
    {pid, name} = start_project!(name: :command_frecency_roundtrip)

    Project.record_command(name, :save)
    scores = Project.command_frecency_scores(name)

    assert scores.save > 0
    assert File.read!(file) =~ "save"

    GenServer.stop(pid)
    {reloaded_pid, reloaded_name} = start_project!(name: :command_frecency_roundtrip)

    assert Project.command_frecency_scores(reloaded_name).save > 0

    GenServer.stop(reloaded_pid)
  end

  test "stale and malformed persisted lines are skipped on load" do
    File.write!(
      command_frecency_path(),
      "save\t100\nElixir.MingaEditor.UI.Picker.CommandSource\t200\nnot-a-line\n"
    )

    {pid, name} = start_project!(name: :command_frecency_validation)
    scores = Project.command_frecency_scores(name)

    assert scores.save > 0
    refute Map.has_key?(scores, MingaEditor.UI.Picker.CommandSource)

    GenServer.stop(pid)
  end

  test "keyboard command selections record command frecency" do
    state = picker_state(CommandSource, [%Item{id: :save, label: "󰘳 save: Save file"}], nil)

    assert {_state, {:execute_command, :save}} = PickerUI.handle_key(state, 13, 0)
    assert Project.command_frecency_scores().save > 0
  end

  test "scopeable command selections record after scope choice" do
    {:ok, buf} = BufferProcess.start_link(content: "hello")
    ctx = %{option_name: :wrap, new_value: true, command_name: :toggle_wrap}
    state = %{workspace: %{buffers: %{active: buf}}, shell_state: %ShellState{status_msg: nil}}

    assert %{shell_state: %{status_msg: status}} =
             OptionScopeSource.on_select(
               %Item{id: {:buffer, ctx}, label: "This Buffer", description: ""},
               state
             )

    assert status =~ "this buffer"
    assert Project.command_frecency_scores().toggle_wrap > 0
  end

  test "mouse command selections record command frecency without polluting other pickers" do
    {buffer, _path} = save_buffer()

    command_state =
      picker_state(CommandSource, [%Item{id: :save, label: "󰘳 save: Save file"}], buffer)

    assert {:handled, _state} =
             PickerInput.handle_mouse(command_state, 28, 10, :left, 0, :press, 1)

    assert Project.command_frecency_scores().save > 0

    reset_global_command_frecency()

    non_command_state =
      picker_state(
        Minga.Test.PendingCommandPickerSource,
        [%Item{id: :pick, label: "Pick"}],
        buffer
      )

    assert {:handled, _state} =
             PickerInput.handle_mouse(non_command_state, 28, 10, :left, 0, :press, 1)

    refute Map.has_key?(Project.command_frecency_scores(), :save)
  end

  defp record_global_command(command, count) do
    Enum.each(1..count, fn _ -> Project.record_command(command) end)
    Project.command_frecency_scores()
  end

  defp index_of(items, id) do
    index = Enum.find_index(items, &(&1.id == id))
    assert is_integer(index)
    index
  end

  defp reset_global_command_frecency do
    restore_global_command_frecency(%{})
  end

  defp restore_global_command_frecency(frecency) do
    :sys.replace_state(Project, fn state -> %{state | command_frecency: frecency} end)
  end

  defp start_project!(opts) do
    name = Keyword.get(opts, :name, :"command_frecency_#{System.unique_integer([:positive])}")

    start_opts =
      opts
      |> Keyword.drop([:name])
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:subscribe, false)

    {:ok, pid} = Project.start_link(start_opts)
    {pid, name}
  end

  defp command_frecency_path do
    Path.join([System.fetch_env!("XDG_CONFIG_HOME"), "minga", "command-frecency"])
  end

  defp restore_xdg_config_home(nil), do: System.delete_env("XDG_CONFIG_HOME")
  defp restore_xdg_config_home(value), do: System.put_env("XDG_CONFIG_HOME", value)

  defp save_buffer do
    path =
      Path.join(System.tmp_dir!(), "command-frecency-#{System.unique_integer([:positive])}.txt")

    File.write!(path, "hello")
    {start_supervised!({BufferProcess, file_path: path}), path}
  end

  defp picker_state(source, items, buffer_pid) do
    viewport = Viewport.new(30, 80)
    picker = Picker.new(items, title: source.title())
    picker_state = %PickerState{picker: picker, source: source, restore: 0}

    %EditorState{
      port_manager: nil,
      terminal_viewport: viewport,
      workspace: %SessionState{
        viewport: viewport,
        editing: VimState.new(),
        buffers: %Buffers{active: buffer_pid, list: maybe_list(buffer_pid), active_index: 0}
      },
      shell_state: %ShellState{modal: {:picker, PickerPayload.new(picker_state)}}
    }
  end

  defp maybe_list(nil), do: []
  defp maybe_list(pid), do: [pid]
end
