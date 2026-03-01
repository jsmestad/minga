defmodule Minga.Editor.Commands.BufferManagement do
  @moduledoc """
  Buffer management commands: save/reload/quit, buffer list/navigation/kill,
  ex-command dispatch, and line number style cycling.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.Commands.Search, as: SearchCommands
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  require Logger

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  # ── Save / quit ───────────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :save) do
    case BufferServer.save(buf) do
      :ok ->
        name = Helpers.buffer_display_name(buf)
        %{state | status_msg: "Wrote #{name}"}

      {:error, :file_changed} ->
        %{state | status_msg: "WARNING: File changed on disk. Use :w! to force save."}

      {:error, :no_file_path} ->
        %{state | status_msg: "No file name — use :w <filename>"}

      {:error, reason} ->
        %{state | status_msg: "Save failed: #{inspect(reason)}"}
    end
  end

  def execute(%{buffer: buf} = state, :force_save) do
    case BufferServer.force_save(buf) do
      :ok ->
        name = Helpers.buffer_display_name(buf)
        %{state | status_msg: "Wrote #{name} (force)"}

      {:error, :no_file_path} ->
        %{state | status_msg: "No file name — use :w <filename>"}

      {:error, reason} ->
        %{state | status_msg: "Force save failed: #{inspect(reason)}"}
    end
  end

  def execute(%{buffer: buf} = state, :reload) do
    case BufferServer.reload(buf) do
      :ok ->
        name = Helpers.buffer_display_name(buf)
        %{state | status_msg: "Reloaded #{name}"}

      {:error, :no_file_path} ->
        %{state | status_msg: "No file to reload"}

      {:error, reason} ->
        %{state | status_msg: "Reload failed: #{inspect(reason)}"}
    end
  end

  def execute(state, :quit) do
    System.stop(0)
    state
  end

  # ── Buffer navigation ─────────────────────────────────────────────────────

  def execute(state, :buffer_list) do
    PickerUI.open(state, Minga.Picker.BufferSource)
  end

  def execute(state, :buffer_next), do: next_buffer(state)
  def execute(state, :buffer_prev), do: prev_buffer(state)
  def execute(state, :kill_buffer), do: remove_current_buffer(state)

  # ── Line number style ─────────────────────────────────────────────────────

  def execute(state, :cycle_line_numbers) do
    next =
      case state.line_numbers do
        :hybrid -> :absolute
        :absolute -> :relative
        :relative -> :none
        :none -> :hybrid
      end

    %{state | line_numbers: next}
  end

  # ── Ex commands ───────────────────────────────────────────────────────────

  def execute(state, {:execute_ex_command, {:save, []}}) do
    execute(state, :save)
  end

  def execute(state, {:execute_ex_command, {:force_save, []}}) do
    execute(state, :force_save)
  end

  def execute(state, {:execute_ex_command, {:force_edit, []}}) do
    execute(state, :reload)
  end

  def execute(state, {:execute_ex_command, {:checktime, []}}) do
    Minga.FileWatcher.check_all()
    state
  end

  def execute(state, {:execute_ex_command, {:quit, []}}) do
    execute(state, :quit)
  end

  def execute(state, {:execute_ex_command, {:force_quit, []}}) do
    Logger.debug("Force quitting editor")
    System.stop(0)
    state
  end

  def execute(state, {:execute_ex_command, {:save_quit, []}}) do
    state_after_save = execute(state, :save)
    Logger.debug("Quitting editor after save")
    System.stop(0)
    state_after_save
  end

  def execute(state, {:execute_ex_command, {:edit, file_path}}) do
    case find_buffer_by_path(state, file_path) do
      nil ->
        case Commands.start_buffer(file_path) do
          {:ok, pid} ->
            Commands.add_buffer(state, pid)

          {:error, reason} ->
            Logger.error("Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        switch_to_buffer(state, idx)
    end
  end

  def execute(%{buffer: buf} = state, {:execute_ex_command, {:goto_line, line_num}}) do
    target_line = max(0, line_num - 1)
    BufferServer.move_to(buf, {target_line, 0})
    state
  end

  def execute(state, {:execute_ex_command, {:set, :number}}) do
    %{state | line_numbers: :absolute}
  end

  def execute(state, {:execute_ex_command, {:set, :nonumber}}) do
    %{state | line_numbers: :none}
  end

  def execute(state, {:execute_ex_command, {:set, :relativenumber}}) do
    new_style =
      case state.line_numbers do
        :absolute -> :hybrid
        _ -> :relative
      end

    %{state | line_numbers: new_style}
  end

  def execute(state, {:execute_ex_command, {:set, :norelativenumber}}) do
    new_style =
      case state.line_numbers do
        :hybrid -> :absolute
        _ -> :none
      end

    %{state | line_numbers: new_style}
  end

  def execute(
        %{buffer: buf} = state,
        {:execute_ex_command, {:substitute, pattern, replacement, flags}}
      ) do
    global? = :global in flags
    confirm? = :confirm in flags

    if confirm? do
      %{state | status_msg: "Confirm mode not yet supported, use /g"}
    else
      SearchCommands.execute_substitute(state, buf, pattern, replacement, global?)
    end
  end

  def execute(state, {:execute_ex_command, {:unknown, raw}}) do
    Logger.debug("Unknown ex command: #{raw}")
    state
  end

  # ── Private buffer helpers ────────────────────────────────────────────────

  @spec switch_to_buffer(state(), non_neg_integer()) :: state()
  defp switch_to_buffer(%{buffers: [_ | _] = buffers} = state, idx) do
    len = Enum.count(buffers)
    idx = rem(idx, len)
    idx = if idx < 0, do: idx + len, else: idx
    pid = Enum.at(buffers, idx)
    %{state | active_buffer: idx, buffer: pid}
  end

  defp switch_to_buffer(state, _idx), do: state

  @spec next_buffer(state()) :: state()
  defp next_buffer(%{buffers: [_, _ | _] = buffers, active_buffer: idx} = state) do
    switch_to_buffer(state, rem(idx + 1, Enum.count(buffers)))
  end

  defp next_buffer(state), do: state

  @spec prev_buffer(state()) :: state()
  defp prev_buffer(%{buffers: [_, _ | _] = buffers, active_buffer: idx} = state) do
    len = Enum.count(buffers)
    new_idx = if idx == 0, do: len - 1, else: idx - 1
    switch_to_buffer(state, new_idx)
  end

  defp prev_buffer(state), do: state

  @spec remove_current_buffer(state()) :: state()
  defp remove_current_buffer(%{buffers: [_ | _] = buffers, active_buffer: idx} = state) do
    buf = Enum.at(buffers, idx)
    if buf && Process.alive?(buf), do: GenServer.stop(buf, :normal)

    new_buffers = List.delete_at(buffers, idx)

    case new_buffers do
      [] ->
        %{state | buffers: [], active_buffer: 0, buffer: nil}

      _ ->
        new_idx = min(idx, Enum.count(new_buffers) - 1)
        new_active = Enum.at(new_buffers, new_idx)
        %{state | buffers: new_buffers, active_buffer: new_idx, buffer: new_active}
    end
  end

  defp remove_current_buffer(state), do: state

  @spec find_buffer_by_path(state(), String.t()) :: non_neg_integer() | nil
  defp find_buffer_by_path(%{buffers: buffers}, file_path) do
    Enum.find_index(buffers, fn buf ->
      Process.alive?(buf) && BufferServer.file_path(buf) == file_path
    end)
  end
end
