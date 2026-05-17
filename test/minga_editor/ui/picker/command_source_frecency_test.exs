defmodule MingaEditor.UI.Picker.CommandSourceFrecencyTest do
  @moduledoc "Tests command palette frecency ordering, persistence, and mouse recording."

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
  alias MingaEditor.Workspace.State, as: WorkspaceState

  setup %{tmp_dir: tmp_dir} do
    previous_config_home = System.get_env("XDG_CONFIG_HOME")
    config_home = Path.join(tmp_dir, "config")
    File.mkdir_p!(Path.join(config_home, "minga"))
    System.put_env("XDG_CONFIG_HOME", config_home)

    previous_state = :sys.get_state(Project)
    :sys.replace_state(Project, fn state -> %{state | command_frecency: %{}} end)

    on_exit(fn ->
      restore_xdg_config_home(previous_config_home)

      :sys.replace_state(Project, fn state ->
        %{state | command_frecency: previous_state.command_frecency}
      end)
    end)

    :ok
  end

  test "recently executed commands are ranked before alphabetical commands" do
    Enum.each(1..5, fn _ ->
      Project.record_command(:quit)
      :sys.get_state(Project)
    end)

    items = CommandSource.candidates(nil)
    quit_index = Enum.find_index(items, &(&1.id == :quit))
    save_index = Enum.find_index(items, &(&1.id == :save))

    assert is_integer(quit_index)
    assert is_integer(save_index)
    assert quit_index < save_index
  end

  test "typed queries still re-rank by fuzzy match after frecency pre-ordering" do
    Enum.each(1..5, fn _ ->
      Project.record_command(:quit_all)
      :sys.get_state(Project)
    end)

    Project.record_command(:quit)
    :sys.get_state(Project)

    candidates = CommandSource.candidates(nil)
    quit_index = Enum.find_index(candidates, &(&1.id == :quit))
    quit_all_index = Enum.find_index(candidates, &(&1.id == :quit_all))

    assert is_integer(quit_index)
    assert is_integer(quit_all_index)
    assert quit_all_index < quit_index

    picker = Picker.new(candidates, title: CommandSource.title())
    filtered = Picker.filter(picker, "q")

    assert Picker.selected_id(filtered) == :quit
  end

  test "persisted command frecency reloads from the XDG config path" do
    project_name = :command_frecency_roundtrip
    command_frecency_file = command_frecency_path()
    File.rm(command_frecency_file)

    {pid, name} = start_project!(name: project_name)
    Project.record_command(name, :save)
    :sys.get_state(name)

    assert File.exists?(command_frecency_file)
    assert File.read!(command_frecency_file) =~ "save"

    GenServer.stop(pid)
    {reloaded_pid, reloaded_name} = start_project!(name: project_name)

    assert Project.command_frecency_scores(reloaded_name).save > 0

    GenServer.stop(reloaded_pid)
  end

  test "persisted command frecency reload keeps the newest events within the limit" do
    command_frecency_file = command_frecency_path()
    newest_first = Enum.to_list(1_000..976//-1)

    content = Enum.map_join(newest_first, "\n", fn timestamp -> "save\t#{timestamp}" end)

    File.write!(command_frecency_file, content <> "\n")

    {pid, name} = start_project!(name: :command_frecency_limit_reload)
    state = :sys.get_state(name)

    assert state.command_frecency.save == Enum.take(newest_first, 20)

    GenServer.stop(pid)
  end

  test "stale and malformed persisted lines are skipped on load" do
    command_frecency_file = command_frecency_path()

    File.write!(
      command_frecency_file,
      "save\t100\nElixir.MingaEditor.UI.Picker.CommandSource\t200\nnot-a-line\n"
    )

    {pid, name} = start_project!(name: :command_frecency_validation)
    scores = Project.command_frecency_scores(name)

    assert scores.save > 0
    refute Map.has_key?(scores, MingaEditor.UI.Picker.CommandSource)

    GenServer.stop(pid)
  end

  test "command palette keyboard selection records command frecency" do
    state = picker_state(CommandSource, [%Item{id: :save, label: "󰘳 save: Save file"}], nil)

    assert {_state, {:execute_command, :save}} = PickerUI.handle_key(state, 13, 0)
    assert Project.command_frecency_scores().save > 0
  end

  test "scopeable command palette selections record after scope choice" do
    {:ok, buf} = BufferProcess.start_link(content: "hello")

    ctx = %{option_name: :wrap, new_value: true, command_name: :toggle_wrap}

    state = %{
      workspace: %{buffers: %{active: buf}},
      shell_state: %ShellState{status_msg: nil}
    }

    assert %{shell_state: %{status_msg: status}} =
             OptionScopeSource.on_select(
               %Item{id: {:buffer, ctx}, label: "This Buffer", description: ""},
               state
             )

    assert status =~ "this buffer"
    assert Project.command_frecency_scores().toggle_wrap > 0
  end

  test "command palette mouse selection records command frecency" do
    {buffer, _path} = save_buffer()
    state = picker_state(CommandSource, [%Item{id: :save, label: "󰘳 save: Save file"}], buffer)

    {:handled, _state} = PickerInput.handle_mouse(state, 28, 10, :left, 0, :press, 1)
    :sys.get_state(Project)

    assert Project.command_frecency_scores().save > 0
  end

  test "non-command picker mouse selection does not pollute command frecency" do
    {buffer, _path} = save_buffer()

    state =
      picker_state(
        Minga.Test.PendingCommandPickerSource,
        [%Item{id: :pick, label: "Pick"}],
        buffer
      )

    {:handled, _state} = PickerInput.handle_mouse(state, 28, 10, :left, 0, :press, 1)
    :sys.get_state(Project)

    refute Map.has_key?(Project.command_frecency_scores(), :save)
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

    picker_state = %PickerState{
      picker: picker,
      source: source,
      restore: 0
    }

    %EditorState{
      port_manager: nil,
      terminal_viewport: viewport,
      workspace: %WorkspaceState{
        viewport: viewport,
        editing: VimState.new(),
        buffers: %Buffers{active: buffer_pid, list: maybe_list(buffer_pid), active_index: 0}
      },
      shell_state: %ShellState{
        modal: {:picker, PickerPayload.new(picker_state)}
      }
    }
  end

  defp maybe_list(nil), do: []
  defp maybe_list(pid), do: [pid]
end
