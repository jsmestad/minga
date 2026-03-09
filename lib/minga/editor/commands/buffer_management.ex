defmodule Minga.Editor.Commands.BufferManagement do
  @moduledoc """
  Buffer management commands: save/reload/quit, buffer list/navigation/kill,
  ex-command dispatch, and line number style cycling.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Loader, as: ConfigLoader
  alias Minga.Config.Options, as: ConfigOptions
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.Commands.Movement
  alias Minga.Editor.Commands.Search, as: SearchCommands
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Formatter
  alias Minga.Mode

  require Logger

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  # ── Save / quit ───────────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :save) do
    state = apply_pre_save_transforms(state, buf)

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

  def execute(%{buffers: %{active: buf}} = state, :force_save) do
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

  def execute(%{buffers: %{active: buf}} = state, :reload) do
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

  def execute(state, :buffer_list_all) do
    PickerUI.open(state, Minga.Picker.BufferAllSource)
  end

  def execute(state, :buffer_next), do: next_buffer(state)
  def execute(state, :buffer_prev), do: prev_buffer(state)
  def execute(state, :kill_buffer), do: remove_current_buffer(state)

  def execute(state, :new_buffer) do
    n = next_new_buffer_number(state.buffers.list)
    name = "[new #{n}]"

    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {BufferServer, content: "", buffer_name: name}
         ) do
      {:ok, pid} ->
        Commands.add_buffer(state, pid)

      {:error, reason} ->
        Logger.error("Failed to create buffer: #{inspect(reason)}")
        state
    end
  end

  def execute(%{buffers: %{scratch: nil}} = state, :view_scratch) do
    %{state | status_msg: "No scratch buffer"}
  end

  def execute(%{buffers: %{scratch: scratch_buf}} = state, :view_scratch) do
    idx = Enum.find_index(state.buffers.list, &(&1 == scratch_buf))

    case idx do
      nil ->
        Commands.add_buffer(state, scratch_buf)

      i ->
        switch_to_buffer(state, i)
    end
  end

  def execute(%{buffers: %{messages: nil}} = state, :view_messages) do
    %{state | status_msg: "No messages buffer"}
  end

  def execute(%{buffers: %{messages: msg_buf}} = state, :view_messages) do
    # Add messages buffer to buffer list if not already there, then switch to it
    idx = Enum.find_index(state.buffers.list, &(&1 == msg_buf))

    case idx do
      nil ->
        Commands.add_buffer(state, msg_buf)

      i ->
        switch_to_buffer(state, i)
    end
  end

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

  def execute(state, :toggle_wrap) do
    current = ConfigOptions.get(:wrap)
    ConfigOptions.set(:wrap, !current)
    label = if current, do: "nowrap", else: "wrap"
    %{state | status_msg: "wrap #{label}"}
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

  def execute(%{buffers: %{active: buf}} = state, {:execute_ex_command, {:goto_line, line_num}}) do
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

  def execute(state, {:execute_ex_command, {:set, :wrap}}) do
    ConfigOptions.set(:wrap, true)
    state
  end

  def execute(state, {:execute_ex_command, {:set, :nowrap}}) do
    ConfigOptions.set(:wrap, false)
    state
  end

  def execute(
        %{buffers: %{active: buf}} = state,
        {:execute_ex_command, {:substitute, pattern, replacement, flags}}
      ) do
    global? = :global in flags
    confirm? = :confirm in flags

    if confirm? do
      SearchCommands.start_substitute_confirm(state, buf, pattern, replacement, global?)
    else
      SearchCommands.execute_substitute(state, buf, pattern, replacement, global?)
    end
  end

  def execute(state, {:execute_ex_command, {:new_buffer, []}}) do
    execute(state, :new_buffer)
  end

  def execute(state, {:execute_ex_command, {:reload_highlights, []}}) do
    HighlightSync.setup_for_buffer(state)
  end

  def execute(state, {:execute_ex_command, {:split_vertical, []}}) do
    Movement.execute(state, :split_vertical)
  end

  def execute(state, {:execute_ex_command, {:split_horizontal, []}}) do
    Movement.execute(state, :split_horizontal)
  end

  def execute(state, {:execute_ex_command, {:window_close, []}}) do
    Movement.execute(state, :window_close)
  end

  def execute(state, {:execute_ex_command, {:unknown, raw}}) do
    Logger.debug("Unknown ex command: #{raw}")
    state
  end

  # ── Open config file ─────────────────────────────────────────────────────

  def execute(state, :open_config) do
    config_path =
      try do
        ConfigLoader.config_path()
      catch
        :exit, _ -> Path.expand("~/.config/minga/config.exs")
      end

    # Ensure the directory exists
    config_dir = Path.dirname(config_path)
    File.mkdir_p(config_dir)

    # Create the file with a starter template if it doesn't exist
    unless File.exists?(config_path) do
      File.write!(config_path, """
      use Minga.Config

      # Options
      # set :tab_width, 2
      # set :line_numbers, :hybrid
      # set :autopair, true
      # set :scroll_margin, 5

      # Font (GUI backend only; no effect in TUI mode)
      # set :font_family, "JetBrains Mono"
      # set :font_size, 14
      # set :font_ligatures, true

      # Per-filetype overrides
      # for_filetype :go, tab_width: 8
      # for_filetype :python, tab_width: 4

      # Keybindings
      # bind :normal, "SPC g s", :git_status, "Git status"

      # Custom commands
      # command :git_status, "Show git status" do
      #   {output, _} = System.cmd("git", ["status", "--short"])
      #   Minga.API.message(output)
      # end

      # Hooks
      # on :after_save, fn _buf, path ->
      #   System.cmd("mix", ["format", path])
      # end
      """)
    end

    case Commands.start_buffer(config_path) do
      {:ok, pid} ->
        EditorState.add_buffer(state, pid)

      {:error, reason} ->
        Logger.warning("Failed to open config: #{inspect(reason)}")
        state
    end
  end

  # ── Private buffer helpers ────────────────────────────────────────────────

  @spec switch_to_buffer(state(), non_neg_integer()) :: state()
  defp switch_to_buffer(state, idx), do: EditorState.switch_buffer(state, idx)

  @spec next_buffer(state()) :: state()
  defp next_buffer(%{buffers: %{list: [_, _ | _] = buffers, active_index: idx}} = state) do
    switch_to_buffer(state, rem(idx + 1, Enum.count(buffers)))
  end

  defp next_buffer(state), do: state

  @spec prev_buffer(state()) :: state()
  defp prev_buffer(%{buffers: %{list: [_, _ | _] = buffers, active_index: idx}} = state) do
    len = Enum.count(buffers)
    new_idx = if idx == 0, do: len - 1, else: idx - 1
    switch_to_buffer(state, new_idx)
  end

  defp prev_buffer(state), do: state

  @spec remove_current_buffer(state()) :: state()

  # Active buffer is scratch (not in buffer list) — clear it
  defp remove_current_buffer(%{buffers: %{list: [], active: buf, scratch: buf}} = state)
       when is_pid(buf) do
    :sys.replace_state(buf, fn s ->
      %{
        s
        | document:
            Document.new(
              "# This buffer is for notes you don't want to save.\n# It will persist across buffer switches.\n\n"
            )
      }
    end)

    %{state | status_msg: "Buffer is persistent — content cleared"}
  end

  defp remove_current_buffer(
         %{buffers: %{list: [_ | _] = buffers, active_index: idx} = bs} = state
       ) do
    buf = Enum.at(buffers, idx)

    # Check if persistent — if so, recreate instead of removing
    if buf && Process.alive?(buf) && BufferServer.persistent?(buf) do
      # Clear buffer content instead of killing it
      buf_state = :sys.get_state(buf)

      initial =
        if buf_state.name == "*scratch*",
          do:
            "# This buffer is for notes you don't want to save.\n# It will persist across buffer switches.\n\n",
          else: ""

      :sys.replace_state(buf, fn s ->
        %{s | document: Document.new(initial)}
      end)

      %{state | status_msg: "Buffer is persistent — content cleared"}
    else
      buf_name =
        if buf && Process.alive?(buf) do
          Helpers.buffer_display_name(buf)
        else
          "[unknown]"
        end

      if buf && Process.alive?(buf), do: GenServer.stop(buf, :normal)
      Minga.Editor.log_to_messages("Closed: #{buf_name}")

      new_buffers = List.delete_at(buffers, idx)

      case new_buffers do
        [] ->
          # Fall back to scratch buffer if available
          fallback = bs.scratch

          %{state | buffers: %{bs | list: [], active_index: 0, active: fallback}}
          |> EditorState.sync_active_window_buffer()

        _ ->
          new_idx = min(idx, Enum.count(new_buffers) - 1)
          new_active = Enum.at(new_buffers, new_idx)

          %{
            state
            | buffers: %{bs | list: new_buffers, active_index: new_idx, active: new_active}
          }
          |> EditorState.sync_active_window_buffer()
      end
    end
  end

  defp remove_current_buffer(state), do: state

  @spec find_buffer_by_path(state(), String.t()) :: non_neg_integer() | nil
  defp find_buffer_by_path(%{buffers: %{list: buffers}}, file_path) do
    Enum.find_index(buffers, fn buf ->
      Process.alive?(buf) && BufferServer.file_path(buf) == file_path
    end)
  end

  @spec next_new_buffer_number([pid()]) :: pos_integer()
  defp next_new_buffer_number(buffers) do
    existing =
      buffers
      |> Enum.filter(&Process.alive?/1)
      |> Enum.map(&BufferServer.buffer_name/1)
      |> Enum.flat_map(fn
        "[new " <> rest ->
          case Integer.parse(String.trim_trailing(rest, "]")) do
            {n, ""} -> [n]
            _ -> []
          end

        _ ->
          []
      end)

    case existing do
      [] -> 1
      nums -> Enum.max(nums) + 1
    end
  end

  # ── Pre-save transforms ─────────────────────────────────────────────────

  @spec apply_pre_save_transforms(state(), pid()) :: state()
  defp apply_pre_save_transforms(state, buf) when is_pid(buf) do
    filetype = BufferServer.filetype(buf)

    state = maybe_format_on_save(state, buf, filetype)
    apply_whitespace_transforms(buf, filetype)
    state
  end

  @spec maybe_format_on_save(state(), pid(), atom()) :: state()
  defp maybe_format_on_save(state, buf, filetype) do
    if ConfigOptions.get_for_filetype(:format_on_save, filetype) do
      run_format_on_save(state, buf, filetype)
    else
      state
    end
  end

  @spec run_format_on_save(state(), pid(), atom()) :: state()
  defp run_format_on_save(state, buf, filetype) do
    file_path = BufferServer.file_path(buf)
    spec = Formatter.resolve_formatter(filetype, file_path)
    buf_name = Helpers.buffer_display_name(buf)

    case {spec, spec && Formatter.format(BufferServer.content(buf), spec)} do
      {nil, _} ->
        state

      {_, {:ok, formatted}} ->
        BufferServer.replace_content(buf, formatted)
        Minga.Editor.log_to_messages("Format-on-save: #{buf_name}")
        state

      {_, {:error, msg}} ->
        Minga.Editor.log_to_messages("Format-on-save failed: #{buf_name} (#{msg})")
        Logger.warning("Format-on-save failed: #{msg}")
        state
    end
  end

  @spec apply_whitespace_transforms(pid(), atom()) :: :ok
  defp apply_whitespace_transforms(buf, filetype) do
    needs_trim = ConfigOptions.get_for_filetype(:trim_trailing_whitespace, filetype)
    needs_final_newline = ConfigOptions.get_for_filetype(:insert_final_newline, filetype)

    if needs_trim or needs_final_newline do
      content = BufferServer.content(buf)
      transformed = Formatter.apply_save_transforms(content, filetype)

      if transformed != content do
        BufferServer.replace_content(buf, transformed)
      end
    end

    :ok
  end
end
