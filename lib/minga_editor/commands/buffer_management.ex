defmodule MingaEditor.Commands.BufferManagement do
  @moduledoc """
  Buffer management commands: save/reload/quit, buffer list/navigation/kill,
  ex-command dispatch, and line number style cycling.
  """

  use MingaEditor.Commands.Provider

  alias MingaAgent.Session
  alias Minga.Buffer
  alias Minga.FileRef
  alias Minga.Buffer.Document
  alias Minga.Config

  alias MingaEditor.Commands
  alias MingaEditor.Commands.Helpers
  alias MingaEditor.Commands.Movement
  alias MingaEditor.Commands.Search, as: SearchCommands
  alias MingaEditor.HighlightSync
  alias MingaEditor.PickerUI
  alias MingaEditor.SemanticTokenSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.Window
  alias Minga.Mode
  alias Minga.Mode.ToolConfirmState
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry
  alias MingaEditor.UI.Popup.Lifecycle, as: PopupLifecycle
  alias MingaEditor.Session.State, as: SessionState

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  # ── Save / quit ───────────────────────────────────────────────────────────

  def execute(%{workspace: %{dired: %{active?: true}}} = state, :save) do
    MingaEditor.Commands.Dired.execute(state, :dired_apply_changes)
  end

  def execute(%{workspace: %{dired: %{active?: true}}} = state, :force_save) do
    MingaEditor.Commands.Dired.execute(state, :dired_apply_changes)
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :save) do
    state = apply_pre_save_transforms(state, buf)

    case Buffer.save(buf) do
      :ok ->
        name = Helpers.buffer_display_name(buf)

        EditorState.set_status(state, "Wrote #{name}")

      {:error, :file_changed} ->
        handle_file_changed_on_save(state, buf)

      {:error, :no_file_path} ->
        EditorState.set_status(state, "No file name — use :w <filename>")

      {:error, reason} ->
        EditorState.set_status(state, "Save failed: #{inspect(reason)}")
    end
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :force_save) do
    case Buffer.force_save(buf) do
      :ok ->
        name = Helpers.buffer_display_name(buf)
        EditorState.set_status(state, "Wrote #{name} (force)")

      {:error, :no_file_path} ->
        EditorState.set_status(state, "No file name — use :w <filename>")

      {:error, reason} ->
        EditorState.set_status(state, "Force save failed: #{inspect(reason)}")
    end
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :reload) do
    case Buffer.reload(buf) do
      :ok ->
        name = Helpers.buffer_display_name(buf)
        EditorState.set_status(state, "Reloaded #{name}")

      {:error, :no_file_path} ->
        EditorState.set_status(state, "No file to reload")

      {:error, reason} ->
        EditorState.set_status(state, "Reload failed: #{inspect(reason)}")
    end
  end

  def execute(state, :quit) do
    maybe_confirm_quit(state, :quit)
  end

  def execute(state, :force_quit), do: close_tab_or_quit(state)
  def execute(state, :close_other_tabs), do: close_other_tabs(state)
  def execute(state, :quit_all), do: maybe_confirm_quit(state, :quit_all)
  def execute(state, :force_quit_all), do: shutdown_editor(state)
  def execute(state, :abort_quit), do: abort_quit_editor(state)

  def execute(%{pending_quit: kind} = state, :confirm_quit_yes) when kind != nil do
    state = EditorState.clear_pending_quit(state)

    case kind do
      :quit -> close_tab_or_quit(state)
      :quit_all -> shutdown_editor(state)
    end
  end

  def execute(state, :confirm_quit_no) do
    state
    |> EditorState.clear_pending_quit()
    |> EditorState.clear_status()
  end

  # ── Buffer navigation ─────────────────────────────────────────────────────

  def execute(state, :buffer_list) do
    PickerUI.open(state, MingaEditor.UI.Picker.BufferSource)
  end

  def execute(state, :buffer_list_all) do
    PickerUI.open(state, MingaEditor.UI.Picker.BufferAllSource)
  end

  def execute(state, :buffer_next), do: next_buffer(state)
  def execute(state, :buffer_prev), do: prev_buffer(state)
  def execute(state, :tab_next), do: next_tab(state)
  def execute(state, :tab_prev), do: prev_tab(state)

  def execute(state, :kill_buffer) do
    case EditorState.active_tab_kind(state) do
      :agent -> close_agent_tab(state)
      _ -> remove_current_buffer(state)
    end
  end

  def execute(state, :new_buffer) do
    n = next_new_buffer_number(state.workspace.buffers.list)
    name = "[new #{n}]"

    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {Minga.Buffer,
            content: "", buffer_name: name, options_server: EditorState.options_server(state)}
         ) do
      {:ok, pid} ->
        Commands.add_buffer(state, pid)

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to create buffer: #{inspect(reason)}")
        state
    end
  end

  def execute(state, :view_messages), do: frontend(state).view_messages(state)
  def execute(state, :view_warnings), do: frontend(state).view_warnings(state)

  def execute(state, {:open_special_buffer, buffer_name, buffer_pid})
      when is_binary(buffer_name) and is_pid(buffer_pid) do
    open_special_buffer(state, buffer_name, buffer_pid)
  end

  # ── Line number style ─────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :cycle_line_numbers)
      when is_pid(buf) do
    current = Buffer.get_option(buf, :line_numbers)

    next =
      case current do
        :hybrid -> :absolute
        :absolute -> :relative
        :relative -> :none
        :none -> :hybrid
      end

    Buffer.set_option(buf, :line_numbers, next)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :toggle_wrap) when is_pid(buf) do
    current = Buffer.get_option(buf, :wrap)
    Buffer.set_option(buf, :wrap, !current)
    label = if current, do: "nowrap", else: "wrap"
    EditorState.set_status(state, "wrap #{label}")
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :toggle_invisible)
      when is_pid(buf) do
    current = Buffer.get_option(buf, :show_invisible)
    Buffer.set_option(buf, :show_invisible, !current)
    label = if current, do: "off", else: "on"
    EditorState.set_status(state, "invisible #{label}")
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

  def execute(state, {:execute_ex_command, {:force_quit, []}}),
    do: execute(state, :force_quit)

  def execute(state, {:execute_ex_command, {:quit_all, []}}),
    do: execute(state, :quit_all)

  def execute(state, {:execute_ex_command, {:force_quit_all, []}}),
    do: execute(state, :force_quit_all)

  def execute(state, {:execute_ex_command, {:abort_quit, []}}),
    do: execute(state, :abort_quit)

  def execute(state, {:execute_ex_command, {:save_quit, []}}) do
    state |> execute(:save) |> close_tab_or_quit()
  end

  def execute(state, {:execute_ex_command, {:save_quit_all, []}}) do
    state |> save_all_buffers() |> shutdown_editor()
  end

  def execute(state, {:execute_ex_command, {:dired, nil}}) do
    MingaEditor.Commands.Dired.execute(state, :dired_open)
  end

  def execute(state, {:execute_ex_command, {:dired, path}}) when is_binary(path) do
    MingaEditor.Commands.Dired.open_directory(state, path)
  end

  def execute(state, {:execute_ex_command, {:edit, file_path}}) do
    open_file_in_active_workspace(state, file_path)
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:goto_line, line_num}}
      ) do
    target_line = max(0, line_num - 1)
    Buffer.move_to(buf, {target_line, 0})
    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:set, :number}}
      )
      when is_pid(buf) do
    Buffer.set_option(buf, :line_numbers, :absolute)
    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:set, :nonumber}}
      )
      when is_pid(buf) do
    Buffer.set_option(buf, :line_numbers, :none)
    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:set, :relativenumber}}
      )
      when is_pid(buf) do
    current = Buffer.get_option(buf, :line_numbers)

    next =
      case current do
        :absolute -> :hybrid
        _ -> :relative
      end

    Buffer.set_option(buf, :line_numbers, next)
    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:set, :norelativenumber}}
      )
      when is_pid(buf) do
    current = Buffer.get_option(buf, :line_numbers)

    next =
      case current do
        :hybrid -> :absolute
        _ -> :none
      end

    Buffer.set_option(buf, :line_numbers, next)
    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:set, :wrap}}
      )
      when is_pid(buf) do
    Buffer.set_option(buf, :wrap, true)
    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:set, :nowrap}}
      )
      when is_pid(buf) do
    Buffer.set_option(buf, :wrap, false)
    state
  end

  # ── :setglobal — writes to the global Options agent ───────────────────────

  def execute(state, {:execute_ex_command, {:setglobal, :number}}) do
    Config.set_option(:line_numbers, :absolute)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :nonumber}}) do
    Config.set_option(:line_numbers, :none)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :relativenumber}}) do
    current = Config.get(:line_numbers)

    next =
      case current do
        :absolute -> :hybrid
        _ -> :relative
      end

    Config.set_option(:line_numbers, next)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :norelativenumber}}) do
    current = Config.get(:line_numbers)

    next =
      case current do
        :hybrid -> :absolute
        _ -> :none
      end

    Config.set_option(:line_numbers, next)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :wrap}}) do
    Config.set_option(:wrap, true)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :nowrap}}) do
    Config.set_option(:wrap, false)
    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
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

  def execute(state, {:execute_ex_command, {:view_warnings, []}}) do
    execute(state, :view_warnings)
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

  def execute(state, {:execute_ex_command, {:set_filetype, [name]}}) do
    case resolve_filetype(name) do
      {:ok, filetype} -> apply_filetype_change(state, filetype)
      {:error, message} -> EditorState.set_status(state, message)
    end
  end

  def execute(state, {:execute_ex_command, {:buffers, []}}) do
    execute(state, :buffer_list_all)
  end

  def execute(state, {:execute_ex_command, {:buffer_next, []}}) do
    execute(state, :buffer_next)
  end

  def execute(state, {:execute_ex_command, {:buffer_prev, []}}) do
    execute(state, :buffer_prev)
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:sort, range, flags}}
      )
      when is_pid(buf) do
    execute_sort(state, buf, range, flags)
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:read, filename}}
      )
      when is_pid(buf) and is_binary(filename) do
    execute_read(state, buf, filename)
  end

  def execute(
        state,
        {:execute_ex_command, {:shell_command, command}}
      )
      when is_binary(command) do
    execute_shell_command(state, command)
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:global, pattern, command}}
      )
      when is_pid(buf) and is_binary(pattern) and is_binary(command) do
    execute_global(state, buf, pattern, command)
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:execute_ex_command, {:normal, range, keys}}
      )
      when is_pid(buf) and is_binary(keys) do
    execute_normal(state, buf, range, keys)
  end

  def execute(state, {:execute_ex_command, {:terminal, []}}) do
    execute_terminal(state)
  end

  def execute(state, {:execute_ex_command, {:unknown, raw}}) do
    Minga.Log.debug(:editor, "Unknown ex command: #{raw}")
    state
  end

  # ── Open config file ─────────────────────────────────────────────────────

  def execute(state, :open_config) do
    config_path =
      try do
        Config.config_path()
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
      # set :font_weight, :regular
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

    case Commands.start_buffer(config_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        EditorState.add_buffer(state, pid)

      {:error, reason} ->
        Minga.Log.warning(:editor, "Failed to open config: #{inspect(reason)}")
        state
    end
  end

  # ── Filetype change ──────────────────────────────────────────────────────

  @doc """
  Changes the active buffer's filetype and triggers a highlight reparse.

  Used by the language picker (`LanguageSource.on_select`) and the `:set ft=`
  ex command. Centralizes the side effects so both paths stay in sync.
  """
  @spec apply_filetype_change(state(), atom()) :: state()
  def apply_filetype_change(state, filetype) when is_atom(filetype) do
    buf = state.workspace.buffers.active

    if is_pid(buf) do
      try do
        Buffer.set_filetype(buf, filetype)
        state = setup_highlight_or_defer(state)
        EditorState.set_status(state, "Language: #{filetype}")
      catch
        :exit, _ -> EditorState.set_status(state, "No active buffer")
      end
    else
      EditorState.set_status(state, "No active buffer")
    end
  end

  # ── Reload config ──────────────────────────────────────────────────────────

  @spec reload_config(state()) :: state()
  def reload_config(state) do
    case Config.reload() do
      :ok ->
        MingaEditor.log_to_messages("Config reloaded")
        EditorState.set_status(state, "Config reloaded")

      {:error, msg} ->
        Minga.Log.warning(:config, "Config reload error: #{msg}")
        EditorState.set_status(state, "Config reload error: #{msg}")
    end
  end

  # ── Alternate file ───────────────────────────────────────────────────────

  @spec alternate_file(state()) :: state()
  def alternate_file(%{workspace: %{buffers: %{active: buf}}} = state) when is_pid(buf) do
    file_path = Buffer.file_path(buf)
    filetype = Buffer.filetype(buf)
    open_alternate(state, file_path, filetype)
  end

  def alternate_file(state), do: EditorState.set_status(state, "No active buffer")

  @spec open_alternate(state(), String.t() | nil, atom()) :: state()
  defp open_alternate(state, nil, _filetype),
    do: EditorState.set_status(state, "Buffer has no file path")

  defp open_alternate(state, file_path, filetype) do
    project_root = Minga.Project.root() || Path.dirname(file_path)
    candidates = Minga.Project.alternate_candidates(file_path, filetype, project_root)

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        EditorState.set_status(state, "No alternate file found for #{Path.basename(file_path)}")

      alt_path ->
        execute(state, {:execute_ex_command, {:edit, alt_path}})
    end
  end

  # ── Tab goto ──────────────────────────────────────────────────────────────

  @spec tab_goto(state(), atom()) :: state()
  def tab_goto(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, cmd) do
    case parse_tab_goto(cmd) do
      {:ok, n} -> switch_tab_by_id_or_index(state, tb, n)
      :error -> state
    end
  end

  def tab_goto(state, _cmd), do: state

  @spec parse_tab_goto(atom()) :: {:ok, pos_integer()} | :error
  defp parse_tab_goto(cmd) do
    case Atom.to_string(cmd) do
      "tab_goto_" <> id_str ->
        case Integer.parse(id_str) do
          {n, ""} -> {:ok, n}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @spec switch_tab_by_id_or_index(EditorState.t(), TabBar.t(), pos_integer()) :: EditorState.t()
  defp switch_tab_by_id_or_index(state, tb, n) do
    if TabBar.has_tab?(tb, n) do
      EditorState.switch_tab(state, n)
    else
      case TabBar.tab_at(tb, n) do
        %{id: id} -> EditorState.switch_tab(state, id)
        nil -> state
      end
    end
  end

  # ── Private buffer helpers ────────────────────────────────────────────────

  @spec execute_terminal(state()) :: state()
  defp execute_terminal(state) do
    EditorState.set_status(state, "Terminal not yet available")
  end

  @spec open_file_in_active_workspace(state(), String.t()) :: state()
  defp open_file_in_active_workspace(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         file_path
       ) do
    file_ref = FileRef.new(file_path)
    workspace_id = TabBar.active_workspace_id(tb)

    case existing_file_tab_in_workspace(state, tb, workspace_id, file_ref) do
      %Tab{id: id} -> EditorState.switch_tab(state, id)
      nil -> start_file_buffer(state, file_path)
    end
  end

  defp open_file_in_active_workspace(state, file_path) do
    start_file_buffer(state, file_path)
  end

  @spec existing_file_tab_in_workspace(state(), TabBar.t(), non_neg_integer(), FileRef.t()) ::
          Tab.t() | nil
  defp existing_file_tab_in_workspace(state, tb, workspace_id, file_ref) do
    if active_buffer_matches_file_ref?(state, file_ref) do
      EditorState.active_tab(state)
    else
      TabBar.find_file_tab_in_workspace(tb, workspace_id, file_ref)
    end
  end

  @spec active_buffer_matches_file_ref?(state(), FileRef.t()) :: boolean()
  defp active_buffer_matches_file_ref?(
         %{workspace: %{buffers: %{active: active}}},
         %FileRef{} = file_ref
       )
       when is_pid(active) do
    case buffer_file_ref(active) do
      %FileRef{} = active_ref -> FileRef.same?(active_ref, file_ref)
      nil -> false
    end
  end

  defp active_buffer_matches_file_ref?(_state, _file_ref), do: false

  @spec start_file_buffer(state(), String.t()) :: state()
  defp start_file_buffer(state, file_path) do
    case Commands.start_buffer(file_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        Commands.add_buffer(state, pid)

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
        state
    end
  end

  @spec switch_to_buffer(state(), non_neg_integer()) :: state()
  defp switch_to_buffer(
         %{shell_state: %{tab_bar: %TabBar{} = tb}, workspace: %{buffers: %{list: buffers}}} =
           state,
         idx
       ) do
    target_buf = Enum.at(buffers, idx)

    case find_tab_for_buffer(tb, target_buf) do
      nil -> EditorState.switch_buffer(state, idx)
      tab_id when tab_id == tb.active_id -> EditorState.switch_buffer(state, idx)
      tab_id -> EditorState.switch_tab(state, tab_id)
    end
  end

  defp switch_to_buffer(state, idx), do: EditorState.switch_buffer(state, idx)

  @spec next_buffer(state()) :: state()
  defp next_buffer(%{workspace: %{buffers: %{active: active, list: buffers}}} = state) do
    buffers
    |> buffer_cycle_order(state)
    |> cycle_buffer_from_active(state, active, 1)
  end

  defp next_buffer(state), do: state

  @spec prev_buffer(state()) :: state()
  defp prev_buffer(%{workspace: %{buffers: %{active: active, list: buffers}}} = state) do
    buffers
    |> buffer_cycle_order(state)
    |> cycle_buffer_from_active(state, active, -1)
  end

  defp prev_buffer(state), do: state

  # Cycles through the current tab's buffer list plus active buffers from dedicated file tabs.
  # Dedicated targets switch tab focus; inline targets switch in-place inside the current tab.
  @spec cycle_buffer_from_active([pid()], state(), pid() | nil, 1 | -1) :: state()
  defp cycle_buffer_from_active([_, _ | _] = buffers, state, active, step) do
    active_index = Enum.find_index(buffers, &(&1 == active)) || 0
    target_index = rem(active_index + step + length(buffers), length(buffers))
    cycle_buffer_in_tab(state, Enum.at(buffers, target_index))
  end

  defp cycle_buffer_from_active(_buffers, state, _active, _step), do: state

  @spec buffer_cycle_order([pid()], state()) :: [pid()]
  defp buffer_cycle_order(buffers, %{shell_state: %{tab_bar: %TabBar{} = tb}}) do
    tab_buffers = visible_file_tab_buffers(tb)
    buffers ++ Enum.reject(tab_buffers, &(&1 in buffers))
  end

  defp buffer_cycle_order(buffers, _state), do: buffers

  @spec visible_file_tab_buffers(TabBar.t()) :: [pid()]
  defp visible_file_tab_buffers(%TabBar{} = tb) do
    Enum.flat_map(TabBar.visible_file_tabs(tb), fn tab ->
      case tab_context_active_buffer(tab) do
        pid when is_pid(pid) -> [pid]
        _ -> []
      end
    end)
  end

  @spec cycle_buffer_in_tab(state(), pid() | nil) :: state()
  defp cycle_buffer_in_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, target_buf) do
    case find_tab_for_buffer(tb, target_buf) do
      nil -> switch_to_buffer_pid(state, target_buf)
      tab_id when tab_id == tb.active_id -> switch_to_buffer_pid(state, target_buf)
      tab_id -> EditorState.switch_tab(state, tab_id)
    end
  end

  defp cycle_buffer_in_tab(state, target_buf), do: switch_to_buffer_pid(state, target_buf)

  @spec switch_to_buffer_pid(state(), pid() | nil) :: state()
  defp switch_to_buffer_pid(state, nil), do: state

  defp switch_to_buffer_pid(%{workspace: %{buffers: %{list: buffers}}} = state, target_buf) do
    case Enum.find_index(buffers, &(&1 == target_buf)) do
      nil -> state
      idx -> EditorState.switch_buffer(state, idx)
    end
  end

  # Finds the file tab whose snapshotted context has `target_buf` as the
  # active buffer. Returns `nil` when no tab matches (the buffer was
  # opened inline in the current tab via `:b<n>` or similar).
  @spec find_tab_for_buffer(TabBar.t(), pid() | nil) :: Tab.id() | nil
  defp find_tab_for_buffer(_tb, nil), do: nil

  defp find_tab_for_buffer(%TabBar{} = tb, target_buf) do
    Enum.find_value(TabBar.visible_file_tabs(tb), fn %{id: id} = tab ->
      case tab_context_active_buffer(tab) do
        ^target_buf -> id
        _ -> nil
      end
    end)
  end

  @spec tab_context_active_buffer(Tab.t() | term()) :: pid() | nil
  defp tab_context_active_buffer(%{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: pid}} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp tab_context_active_buffer(_tab), do: nil

  @spec buffer_file_ref(pid()) :: FileRef.t() | nil
  defp buffer_file_ref(pid) when is_pid(pid) do
    case Buffer.file_path(pid) do
      path when is_binary(path) -> FileRef.new(path)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @spec next_tab(state()) :: state()
  defp next_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    next_tb = TabBar.next(tb)

    if next_tb.active_id != tb.active_id do
      EditorState.switch_tab(state, next_tb.active_id)
    else
      state
    end
  end

  defp next_tab(state), do: state

  @spec prev_tab(state()) :: state()
  defp prev_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    prev_tb = TabBar.prev(tb)

    if prev_tb.active_id != tb.active_id do
      EditorState.switch_tab(state, prev_tb.active_id)
    else
      state
    end
  end

  defp prev_tab(state), do: state

  @spec remove_current_buffer(state()) :: state()

  defp remove_current_buffer(
         %{workspace: %{buffers: %{list: [_ | _] = buffers, active_index: idx} = bs}} = state
       ) do
    buf = Enum.at(buffers, idx)

    # Check if persistent — if so, recreate instead of removing
    persistent? =
      if buf do
        try do
          Buffer.persistent?(buf)
        catch
          :exit, _ -> false
        end
      else
        false
      end

    if persistent? do
      # Clear buffer content instead of killing it
      :sys.replace_state(buf, fn s ->
        %{s | document: Document.new("")}
      end)

      EditorState.set_status(state, "Buffer is persistent — content cleared")
    else
      buf_name =
        if buf do
          try do
            Helpers.buffer_display_name(buf)
          catch
            :exit, _ -> "[unknown]"
          end
        else
          "[unknown]"
        end

      if buf do
        try do
          path = Buffer.file_path(buf) || :scratch

          Minga.Events.broadcast(
            :buffer_closed,
            %Minga.Events.BufferClosedEvent{buffer: buf, path: path},
            EditorState.events_registry(state)
          )

          GenServer.stop(buf, :normal)
        catch
          :exit, _ -> :ok
        end
      end

      # Free the buffer's tree-sitter parse tree in the Zig parser process.
      state = HighlightSync.close_buffer(state, buf)

      MingaEditor.log_to_messages("Closed: #{buf_name}")

      new_buffers = List.delete_at(buffers, idx)
      had_neighbor_tab? = has_neighbor_tab?(state)

      # Remove the current tab from the tab bar (if present).
      # TabBar.remove handles neighbor selection.
      state = remove_current_tab(state)

      case new_buffers do
        [] ->
          restore_neighbor_tab_or_create_fallback(state, bs, had_neighbor_tab?)

        _ ->
          new_idx = min(idx, Enum.count(new_buffers) - 1)
          new_bs = Buffers.replace_list(bs, new_buffers, new_idx)

          state
          |> EditorState.update_workspace(&SessionState.set_buffers(&1, new_bs))
          |> EditorState.sync_active_window_buffer()
      end
    end
  end

  defp remove_current_buffer(state), do: state

  # Pure cleanup: stops the agent session, spinner, and group without
  # touching tabs or navigation. Callers handle tab removal separately.
  @spec cleanup_agent_session(state()) :: state()
  defp cleanup_agent_session(%{shell_state: %{tab_bar: %TabBar{}}} = state) do
    session = AgentAccess.session(state)

    # Stop and unsubscribe from the live session.
    if session do
      try do
        Session.unsubscribe(session)
      catch
        :exit, _ -> :ok
      end

      try do
        GenServer.stop(session, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    state = scrub_agent_tab_state(state, session)
    MingaEditor.log_to_messages("Closed agent tab")
    state
  end

  @doc """
  Cleans up editor state after an agent session dies (`:DOWN` handler).

  The session is already dead, so no stop/unsubscribe is needed. This
  clears the spinner, agent state, tab session/status, and workspace.
  """
  @spec handle_agent_session_down(state(), pid(), term()) :: state()
  def handle_agent_session_down(state, session_pid, :noconnection) do
    handle_remote_session_disconnected(state, session_pid)
  end

  def handle_agent_session_down(state, session_pid, {:nodedown, _node}) do
    handle_remote_session_disconnected(state, session_pid)
  end

  def handle_agent_session_down(state, session_pid, {:noconnection, _node}) do
    handle_remote_session_disconnected(state, session_pid)
  end

  def handle_agent_session_down(
        %{shell: MingaEditor.Shell.Board} = state,
        session_pid,
        reason
      ) do
    card_status = if reason in [:normal, :shutdown], do: :done, else: :errored
    board = state.shell_state

    # Find the card with this session and clear its session pid (the
    # process is dead, so AgentAccess.session/1 must not keep returning
    # it). Update status in the same pass.
    {board, owned?} =
      case Enum.find(board.cards, fn {_id, card} -> card.session == session_pid end) do
        {card_id, _card} ->
          updated =
            MingaEditor.Shell.Board.State.update_card(board, card_id, fn card ->
              card
              |> MingaEditor.Shell.Board.Card.set_status(card_status)
              |> MingaEditor.Shell.Board.Card.detach_session()
            end)

          {updated, true}

        nil ->
          {board, false}
      end

    state = EditorState.update_shell_state(state, fn _ -> board end)
    state = AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)
    state = AgentAccess.update_agent(state, &AgentState.reset_cache/1)

    if owned? do
      msg =
        if reason in [:normal, :shutdown],
          do: "Agent session ended",
          else: "Agent session crashed"

      EditorState.set_status(state, msg)
    else
      Minga.Log.debug(
        :agent,
        "ignoring session-down for non-owned pid #{inspect(session_pid)}"
      )

      state
    end
  end

  def handle_agent_session_down(
        %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
        session_pid,
        reason
      ) do
    owned? =
      Enum.any?(tb.tabs, &(&1.session == session_pid)) or
        TabBar.find_workspace_by_session(tb, session_pid) != nil

    if owned? do
      tab_status = if reason in [:normal, :shutdown], do: :idle, else: :error
      state = scrub_agent_tab_state(state, session_pid, tab_status)

      msg =
        if reason in [:normal, :shutdown],
          do: "Agent session ended",
          else: "Agent session crashed (SPC a n to restart)"

      EditorState.set_status(state, msg)
    else
      Minga.Log.debug(
        :agent,
        "ignoring session-down for non-owned pid #{inspect(session_pid)}"
      )

      state
    end
  end

  @spec handle_remote_session_disconnected(state(), pid()) :: state()
  defp handle_remote_session_disconnected(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         session_pid
       ) do
    case TabBar.find_by_session(tb, session_pid) do
      %Tab{id: tab_id, server_name: server_name} when is_binary(server_name) ->
        tb = TabBar.update_tab(tb, tab_id, &Tab.set_connection_status(&1, :disconnected))

        state
        |> EditorState.set_tab_bar(tb)
        |> AgentAccess.update_agent(&AgentState.stop_spinner_timer/1)
        |> AgentAccess.update_agent(&AgentState.set_error(&1, "Disconnected from #{server_name}"))
        |> EditorState.set_status("[#{server_name}] disconnected, reconnecting...")

      _ ->
        state
    end
  end

  defp handle_remote_session_disconnected(%{shell: MingaEditor.Shell.Board} = state, session_pid) do
    board = state.shell_state

    board =
      case Enum.find(board.cards, fn {_id, card} -> card.session == session_pid end) do
        {card_id, _card} ->
          MingaEditor.Shell.Board.State.update_card(
            board,
            card_id,
            &MingaEditor.Shell.Board.Card.set_connection_status(&1, :disconnected)
          )

        nil ->
          board
      end

    state
    |> EditorState.update_shell_state(fn _ -> board end)
    |> AgentAccess.update_agent(&AgentState.stop_spinner_timer/1)
    |> EditorState.set_status("Remote agent disconnected, reconnecting...")
  end

  defp handle_remote_session_disconnected(state, _session_pid), do: state

  # Shared state cleanup for agent sessions: stops spinner, clears agent state session,
  # clears Tab.session/agent_status, and removes the agent workspace.
  @spec scrub_agent_tab_state(state(), pid() | nil, Tab.agent_status()) :: state()
  defp scrub_agent_tab_state(state, session, tab_status \\ :idle) do
    state = AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)
    state = AgentAccess.update_agent(state, &AgentState.reset_cache/1)

    # Clear session and status on any tab that referenced this session.
    state =
      if session do
        clear_session_from_tabs(state, session, tab_status)
      else
        state
      end

    # Remove the agent's group from the tab bar.
    case session && TabBar.find_workspace_by_session(state.shell_state.tab_bar, session) do
      %{id: workspace_id} ->
        EditorState.set_tab_bar(
          state,
          TabBar.remove_workspace(state.shell_state.tab_bar, workspace_id)
        )

      _ ->
        state
    end
  end

  # Clears session pid and sets agent_status on all tabs that reference
  # the given session pid.
  @spec clear_session_from_tabs(state(), pid(), Tab.agent_status()) :: state()
  defp clear_session_from_tabs(%{shell_state: %{tab_bar: tb}} = state, session_pid, status) do
    updated_tb =
      Enum.reduce(tb.tabs, tb, fn tab, acc ->
        if tab.session == session_pid do
          acc
          |> TabBar.update_tab(tab.id, &Tab.set_session(&1, nil))
          |> TabBar.update_tab(tab.id, &Tab.set_agent_status(&1, status))
        else
          acc
        end
      end)

    EditorState.set_tab_bar(state, updated_tb)
  end

  # Closes the active agent tab: cleans up the session, removes the tab,
  # and switches to the nearest file tab. Only called from multi-tab
  # contexts (close_tab_or_quit's first clause); the last-tab case is
  # handled directly by close_tab_or_quit.
  @spec close_agent_tab(state()) :: state()
  defp close_agent_tab(%{shell_state: %{tab_bar: %TabBar{}}} = state) do
    state
    |> cleanup_agent_session()
    |> EditorState.update_workspace(&SessionState.set_keymap_scope(&1, :editor))
    |> remove_current_tab()
    |> restore_active_tab_context()
  end

  defp close_agent_tab(state), do: state

  # Closes the current tab if multiple tabs are open, or exits the editor
  # if this is the last tab. Mirrors Neovim's `:q` hierarchy: close the
  # smallest container first, only exit when nothing is left to close.
  #
  # For file tabs, this closes the tab without killing the buffer (matching
  # Neovim where `:q` closes the window but the buffer stays in memory).
  # For agent tabs, session cleanup is needed so we delegate to close_agent_tab.
  # Checks whether a quit should be confirmed. Dirty buffers use the existing
  # confirm_quit option; last-file `:q` always asks before exiting so Vim-style
  # close semantics do not surprise users by terminating the app.
  @spec maybe_confirm_quit(state(), :quit | :quit_all) :: state()
  defp maybe_confirm_quit(state, :quit) do
    dirty? = dirty_quit_confirmation_needed?(state)

    if dirty? or quit_would_exit_editor?(state) do
      state
      |> EditorState.set_pending_quit(:quit)
      |> EditorState.set_status(quit_confirmation_message(dirty?))
    else
      close_tab_or_quit(state)
    end
  end

  defp maybe_confirm_quit(state, :quit_all) do
    if dirty_quit_confirmation_needed?(state) do
      state
      |> EditorState.set_pending_quit(:quit_all)
      |> EditorState.set_status("Modified buffers exist. Really quit? (y/n)")
    else
      shutdown_editor(state)
    end
  end

  @spec dirty_quit_confirmation_needed?(state()) :: boolean()
  defp dirty_quit_confirmation_needed?(state) do
    confirm_quit_enabled?(state) and any_buffer_dirty?(state)
  end

  @spec quit_confirmation_message(boolean()) :: String.t()
  defp quit_confirmation_message(true), do: "Modified buffers exist. Quit Minga? (y/n)"
  defp quit_confirmation_message(false), do: "Quit Minga? (y/n)"

  @spec any_buffer_dirty?(state()) :: boolean()
  defp any_buffer_dirty?(state) do
    Enum.any?(state.workspace.buffers.list, fn pid ->
      try do
        Buffer.dirty?(pid)
      catch
        :exit, _ -> false
      end
    end)
  end

  @spec confirm_quit_enabled?(state()) :: boolean()
  defp confirm_quit_enabled?(state) do
    Minga.Config.Options.get(EditorState.options_server(state), :confirm_quit)
  end

  # Validates a filetype name string against the Language registry.
  # Uses String.to_existing_atom to avoid atom table pollution from typos.
  @spec resolve_filetype(String.t()) :: {:ok, atom()} | {:error, String.t()}
  defp resolve_filetype(name) do
    atom = String.to_existing_atom(name)

    case Minga.Language.Registry.get(atom) do
      %Minga.Language{} -> {:ok, atom}
      nil -> {:error, "Unknown language: #{name}"}
    end
  rescue
    ArgumentError -> {:error, "Unknown language: #{name}"}
  end

  @spec close_tab_or_quit(state()) :: state()
  defp close_tab_or_quit(%{shell_state: %{tab_bar: %TabBar{}}} = state) do
    case EditorState.active_tab(state) do
      %Tab{kind: :agent} -> close_agent_tab_or_quit(state)
      %Tab{kind: :file, id: active_id} -> close_file_tab_or_quit(state, active_id)
      _ -> shutdown_editor(state)
    end
  end

  defp close_tab_or_quit(state), do: shutdown_editor(state)

  @spec close_agent_tab_or_quit(state()) :: state()
  defp close_agent_tab_or_quit(%{shell_state: %{tab_bar: %TabBar{tabs: [_single]}}} = state) do
    state
    |> cleanup_agent_session()
    |> shutdown_editor()
  end

  defp close_agent_tab_or_quit(state), do: close_agent_tab(state)

  @spec close_file_tab_or_quit(state(), Tab.id()) :: state()
  defp close_file_tab_or_quit(state, _active_id) do
    tb = EditorState.tab_bar(state)

    if TabBar.count(tb) > 1 do
      close_file_tab(state)
    else
      shutdown_editor(state)
    end
  end

  @spec quit_would_exit_editor?(state()) :: boolean()
  defp quit_would_exit_editor?(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    case EditorState.active_tab(state) do
      %Tab{kind: :file} -> TabBar.count(tb) == 1
      %Tab{kind: :agent} -> TabBar.count(tb) == 1
      _ -> true
    end
  end

  defp quit_would_exit_editor?(_state), do: true

  @spec close_other_tabs(state()) :: state()
  defp close_other_tabs(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    active_id = tb.active_id
    closed_tabs = Enum.reject(TabBar.visible_file_tabs(tb), &(&1.id == active_id))
    tb = remove_tabs(tb, closed_tabs)

    MingaEditor.log_to_messages("Closed other tabs")
    EditorState.set_tab_bar(state, tb)
  end

  defp close_other_tabs(state), do: state

  @spec remove_tabs(TabBar.t(), [Tab.t()]) :: TabBar.t()
  defp remove_tabs(tb, tabs) do
    Enum.reduce(tabs, tb, fn tab, acc ->
      case TabBar.remove(acc, tab.id) do
        {:ok, new_tb} -> new_tb
        :last_tab -> acc
      end
    end)
  end

  # Saves all dirty buffers in the buffer list. Called by :wqa before
  # shutting down. Returns state unchanged (side-effectual only).
  @spec save_all_buffers(state()) :: state()
  defp save_all_buffers(state) do
    Enum.each(state.workspace.buffers.list, fn buf ->
      try do
        if Buffer.dirty?(buf), do: Buffer.save(buf)
      catch
        :exit, _ -> :ok
      end
    end)

    state
  end

  # Exits the editor. Single exit point so shutdown cleanup (flush buffers,
  # save session, etc.) can be added in one place.
  #
  # The shutdown function is injectable via application config so the chaos
  # fuzzer can prevent `System.stop/1` from killing the VM mid-test.
  @spec shutdown_editor(state()) :: state()
  defp shutdown_editor(state) do
    shutdown_fn = Application.get_env(:minga, :shutdown_fn, &System.stop/1)
    shutdown_fn.(0)
    state
  end

  # Aborts the editor with a non-zero exit code. Used by `:cq` / `:cquit`
  # so external tools (like `git commit`) can detect the user cancelled.
  @spec abort_quit_editor(state()) :: state()
  defp abort_quit_editor(state) do
    shutdown_fn = Application.get_env(:minga, :shutdown_fn, &System.stop/1)
    shutdown_fn.(1)
    state
  end

  # Closes the current file tab without killing the buffer. The buffer
  # stays in the buffer pool (matching Neovim's `:q` which closes the
  # window but leaves the buffer in the background buffer list).
  @spec close_file_tab(state()) :: state()
  defp close_file_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    active_tab = EditorState.active_tab(state)
    label = if active_tab, do: active_tab.label, else: "tab"
    replacement_id = active_tab && replacement_tab_id(tb, active_tab)
    MingaEditor.log_to_messages("Closed: #{label}")

    state
    |> remove_current_tab(replacement_id)
    |> restore_active_tab_context()
  end

  @spec has_neighbor_tab?(state()) :: boolean()
  defp has_neighbor_tab?(%{shell_state: %{tab_bar: %TabBar{tabs: [_, _ | _]}}}), do: true
  defp has_neighbor_tab?(_state), do: false

  @spec restore_neighbor_tab_or_create_fallback(
          state(),
          MingaEditor.State.Buffers.t(),
          boolean()
        ) :: state()
  defp restore_neighbor_tab_or_create_fallback(state, _old_buffers, true) do
    state = restore_active_tab_context(state)

    if state.workspace.buffers.active do
      EditorState.sync_active_window_buffer(state)
    else
      create_fallback_buffer(state, state.workspace.buffers)
    end
  end

  defp restore_neighbor_tab_or_create_fallback(state, old_buffers, false) do
    create_fallback_buffer(state, old_buffers)
  end

  @spec remove_current_tab(state(), Tab.id() | nil) :: state()
  defp remove_current_tab(state, replacement_id \\ nil)

  defp remove_current_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, replacement_id) do
    case TabBar.remove(tb, tb.active_id) do
      {:ok, new_tb} ->
        EditorState.set_tab_bar(state, maybe_switch_to_replacement(new_tb, replacement_id))

      :last_tab ->
        state
    end
  end

  defp remove_current_tab(state, _replacement_id), do: state

  @spec maybe_switch_to_replacement(TabBar.t(), Tab.id() | nil) :: TabBar.t()
  defp maybe_switch_to_replacement(tb, nil), do: tb
  defp maybe_switch_to_replacement(tb, replacement_id), do: TabBar.switch_to(tb, replacement_id)

  @spec replacement_tab_id(TabBar.t(), Tab.t()) :: Tab.id() | nil
  defp replacement_tab_id(%TabBar{} = tb, %Tab{id: active_id, group_id: group_id}) do
    replacement_file_tab_id(tb, active_id) ||
      replacement_tab_in_workspace_id(tb, active_id, group_id)
  end

  @spec replacement_file_tab_id(TabBar.t(), Tab.id()) :: Tab.id() | nil
  defp replacement_file_tab_id(%TabBar{} = tb, active_id) do
    tabs = TabBar.visible_file_tabs(tb)

    case Enum.find_index(tabs, &(&1.id == active_id)) do
      nil -> nil
      idx -> replacement_file_tab_id(tabs, idx)
    end
  end

  @spec replacement_file_tab_id([Tab.t()], non_neg_integer()) :: Tab.id() | nil
  defp replacement_file_tab_id(tabs, idx) do
    right = Enum.drop(tabs, idx + 1)
    left = tabs |> Enum.take(idx) |> Enum.reverse()

    case right ++ left do
      [%Tab{id: id} | _] -> id
      [] -> nil
    end
  end

  @spec replacement_tab_in_workspace_id(TabBar.t(), Tab.id(), non_neg_integer()) :: Tab.id() | nil
  defp replacement_tab_in_workspace_id(%TabBar{tabs: tabs}, active_id, group_id) do
    case Enum.find(tabs, &(&1.group_id == group_id and &1.id != active_id)) do
      %Tab{id: id} -> id
      nil -> nil
    end
  end

  # Restores the now-active tab's snapshotted context into live editor state.
  # Called after removing a tab to switch the editor to the neighbor tab's
  # buffers, windows, viewport, etc. No-op for brand-new tabs with no snapshot.
  @spec restore_active_tab_context(state()) :: state()
  defp restore_active_tab_context(state) do
    case EditorState.active_tab(state) do
      %Tab{context: context} when is_map(context) ->
        if TabContext.empty?(context) do
          state
        else
          EditorState.restore_tab_context(state, context)
        end

      _ ->
        state
    end
  end

  @spec next_new_buffer_number([pid()]) :: pos_integer()
  defp next_new_buffer_number(buffers) do
    existing =
      buffers
      |> Enum.flat_map(fn buf ->
        try do
          [Buffer.buffer_name(buf)]
        catch
          :exit, _ -> []
        end
      end)
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
    state = maybe_format_on_save(state, buf, nil)
    apply_whitespace_transforms(buf)
    state
  end

  @spec maybe_format_on_save(state(), pid(), atom()) :: state()
  defp maybe_format_on_save(state, buf, _filetype) do
    if Buffer.get_option(buf, :format_on_save) do
      run_format_on_save(state, buf)
    else
      state
    end
  end

  @spec run_format_on_save(state(), pid()) :: state()
  defp run_format_on_save(state, buf) do
    file_path = Buffer.file_path(buf)
    filetype = Buffer.filetype(buf)
    spec = Minga.Editing.resolve_formatter(filetype, file_path)
    buf_name = Helpers.buffer_display_name(buf)

    case try_lsp_format_on_save(buf) do
      {:ok, _formatted} ->
        MingaEditor.log_to_messages("Format-on-save (LSP): #{buf_name}")
        state

      :not_available ->
        run_external_formatter_on_save(state, buf, spec, buf_name)
    end
  end

  @spec run_external_formatter_on_save(state(), pid(), String.t() | nil, String.t()) :: state()
  defp run_external_formatter_on_save(state, _buf, nil, _buf_name), do: state

  defp run_external_formatter_on_save(state, buf, spec, buf_name) do
    command = spec |> String.split() |> List.first()

    if System.find_executable(command) do
      run_formatter_with_spec(state, buf, spec, buf_name)
    else
      queue_formatter_tool_prompt(state, command)
    end
  end

  # ── LSP format-on-save ─────────────────────────────────────────────────

  # Timeout for LSP formatting during save. Shorter than the interactive
  # formatting timeout (5s) because save should feel instant.
  @lsp_format_on_save_timeout 1_000

  @spec try_lsp_format_on_save(pid()) :: {:ok, String.t()} | :not_available
  defp try_lsp_format_on_save(buf) when is_pid(buf) do
    clients = Minga.LSP.SyncServer.clients_for_buffer(buf)

    case Enum.find(clients, &lsp_supports_formatting?/1) do
      nil ->
        :not_available

      client ->
        do_lsp_format_on_save(buf, client)
    end
  end

  @spec lsp_supports_formatting?(pid()) :: boolean()
  defp lsp_supports_formatting?(client) do
    caps = Minga.LSP.Client.capabilities(client)

    get_in(caps, ["documentFormattingProvider"]) == true or
      get_in(caps, ["textDocument", "formatting", "provider"]) == true
  end

  @spec do_lsp_format_on_save(pid(), pid()) :: {:ok, String.t()} | :not_available
  defp do_lsp_format_on_save(buf, client) do
    file_path = Buffer.file_path(buf)
    uri = Minga.LSP.SyncServer.path_to_uri(file_path)
    tab_size = Buffer.get_option(buf, :tab_width) || 2
    insert_spaces = Buffer.get_option(buf, :indent_with) == :spaces

    params = %{
      "textDocument" => %{"uri" => uri},
      "options" => %{"tabSize" => tab_size, "insertSpaces" => insert_spaces}
    }

    case Minga.LSP.Client.request_sync(
           client,
           "textDocument/formatting",
           params,
           @lsp_format_on_save_timeout
         ) do
      {:ok, edits} when is_list(edits) ->
        content = Buffer.content(buf)
        new_content = apply_lsp_edits_to_content(content, edits)

        if new_content != content do
          {cursor_line, cursor_col} = Buffer.cursor(buf)
          Buffer.replace_content(buf, new_content)
          line_count = Buffer.line_count(buf)
          safe_line = min(cursor_line, max(line_count - 1, 0))
          Buffer.move_to(buf, {safe_line, cursor_col})
        end

        {:ok, new_content}

      {:ok, nil} ->
        :not_available

      {:error, _reason} ->
        :not_available
    end
  end

  @spec apply_lsp_edits_to_content(String.t(), [map()]) :: String.t()
  defp apply_lsp_edits_to_content(content, edits) when is_list(edits) do
    Enum.reduce(Enum.reverse(edits), content, fn edit, acc ->
      range = Map.get(edit, "range", %{})
      new_text = Map.get(edit, "newText", "")
      start_line = get_in(range, ["start", "line"]) || 0
      start_col = get_in(range, ["start", "character"]) || 0
      end_line = get_in(range, ["end", "line"]) || 0
      end_col = get_in(range, ["end", "character"]) || 0

      apply_single_lsp_edit(acc, start_line, start_col, end_line, end_col, new_text)
    end)
  end

  @spec apply_single_lsp_edit(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: String.t()
  defp apply_single_lsp_edit(content, start_line, start_col, end_line, end_col, new_text) do
    lines = String.split(content, "\n")

    case Enum.at(lines, start_line) do
      nil ->
        content

      start_text ->
        case Enum.at(lines, end_line) do
          nil ->
            content

          end_text ->
            before = String.slice(start_text, 0, start_col)
            after_end = String.slice(end_text, end_col..-1//1)
            replacement = before <> new_text <> after_end

            {before_lines, rest} = Enum.split(lines, start_line)
            {_removed, after_lines} = Enum.split(rest, end_line - start_line + 1)

            new_lines = before_lines ++ [replacement] ++ after_lines
            Enum.join(new_lines, "\n")
        end
    end
  end

  @spec run_formatter_with_spec(state(), pid(), String.t(), String.t()) :: state()
  defp run_formatter_with_spec(state, buf, spec, buf_name) do
    case Minga.Editing.format(Buffer.content(buf), spec) do
      {:ok, formatted} ->
        Buffer.replace_content(buf, formatted)
        MingaEditor.log_to_messages("Format-on-save: #{buf_name}")
        state

      {:error, msg} ->
        Minga.Log.warning(:editor, "Format-on-save failed: #{buf_name} (#{msg})")
        state
    end
  end

  @spec queue_formatter_tool_prompt(state(), String.t()) :: state()
  defp queue_formatter_tool_prompt(state, command) do
    case RecipeRegistry.for_command(command) do
      nil ->
        state

      recipe ->
        if EditorState.skip_tool_prompt?(state, recipe.name) do
          state
        else
          queue = state.shell_state.tool_prompt_queue ++ [recipe.name]
          state = EditorState.update_shell_state(state, &%{&1 | tool_prompt_queue: queue})
          show_tool_prompt_if_normal(state)
        end
    end
  end

  @spec show_tool_prompt_if_normal(state()) :: state()
  defp show_tool_prompt_if_normal(
         %{workspace: %{editing: %{mode: :normal}}, shell_state: %{tool_prompt_queue: pending}} =
           state
       )
       when pending != [] do
    ms = %ToolConfirmState{pending: pending, declined: state.shell_state.tool_declined}
    EditorState.transition_mode(state, :tool_confirm, ms)
  end

  defp show_tool_prompt_if_normal(state), do: state

  @spec apply_whitespace_transforms(pid()) :: :ok
  defp apply_whitespace_transforms(buf) do
    needs_trim = Buffer.get_option(buf, :trim_trailing_whitespace)
    needs_final_newline = Buffer.get_option(buf, :insert_final_newline)

    if needs_trim or needs_final_newline do
      content = Buffer.content(buf)
      transformed = Minga.Editing.apply_save_transforms(content, needs_trim, needs_final_newline)

      if transformed != content do
        Buffer.replace_content(buf, transformed)
      end
    end

    :ok
  end

  # Opens a special buffer (like *Messages* or *Warnings*) as a popup if a
  # matching popup rule exists, otherwise falls back to normal buffer switching.
  # If the buffer is already open in a popup, toggles it closed.
  @doc """
  Opens a special buffer in a popup window (TUI) or switches to it.
  Public so `BufferManagement.TUI` can call it for TUI fallback paths.
  """
  @spec open_special_buffer(state(), String.t(), pid()) :: state()
  def open_special_buffer(state, buffer_name, buffer_pid) do
    case find_popup_for_buffer(state, buffer_pid) do
      {:ok, popup_window_id} ->
        # Toggle: close the existing popup
        PopupLifecycle.close_popup(state, popup_window_id)

      :none ->
        open_special_buffer_new(state, buffer_name, buffer_pid)
    end
  end

  # Opens a new popup for the buffer, or falls back to normal buffer switching.
  # Always focuses the popup since this is an explicit user command (not an
  # automatic popup trigger where the rule's focus setting would apply).
  @spec open_special_buffer_new(state(), String.t(), pid()) :: state()
  defp open_special_buffer_new(state, buffer_name, buffer_pid) do
    case PopupLifecycle.open_popup(state, buffer_name, buffer_pid) do
      {:ok, new_state} ->
        focus_popup_window(new_state, buffer_pid)

      :no_match ->
        switch_or_add_buffer(state, buffer_pid)
    end
  end

  # Ensures the popup window displaying the given buffer is focused.
  @spec focus_popup_window(state(), pid()) :: state()
  defp focus_popup_window(state, buffer_pid) do
    case find_popup_for_buffer(state, buffer_pid) do
      {:ok, popup_window_id} ->
        EditorState.update_workspace(state, fn ws ->
          SessionState.set_windows(ws, Windows.set_active(ws.windows, popup_window_id))
        end)

      :none ->
        state
    end
  end

  @spec switch_or_add_buffer(state(), pid()) :: state()
  defp switch_or_add_buffer(state, buffer_pid) do
    idx = Enum.find_index(state.workspace.buffers.list, &(&1 == buffer_pid))

    case idx do
      nil -> Commands.add_buffer(state, buffer_pid)
      i -> switch_to_buffer(state, i)
    end
  end

  # Finds an existing popup window displaying the given buffer pid.
  @spec find_popup_for_buffer(state(), pid()) :: {:ok, Window.id()} | :none
  defp find_popup_for_buffer(state, buffer_pid) do
    result =
      Enum.find(state.workspace.windows.map, fn {_id, window} ->
        Window.popup?(window) and window.buffer == buffer_pid
      end)

    case result do
      {id, _window} -> {:ok, id}
      nil -> :none
    end
  end

  # Creates an empty buffer when the last buffer is killed.
  # Dashboard is disabled pending rewrite as a special buffer.
  @spec create_fallback_buffer(state(), EditorState.Buffers.t()) :: state()
  defp create_fallback_buffer(state, bs) do
    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {Minga.Buffer,
            content: "", buffer_name: "[new 1]", options_server: EditorState.options_server(state)}
         ) do
      {:ok, new_buf} ->
        state
        |> EditorState.update_workspace(
          &SessionState.set_buffers(&1, Buffers.replace_list(bs, [new_buf], 0))
        )
        |> EditorState.sync_active_window_buffer()

      {:error, _} ->
        EditorState.update_workspace(
          state,
          &SessionState.set_buffers(&1, Buffers.replace_list(bs, [], 0))
        )
    end
  end

  command(:save, "Save the current file", requires_buffer: true)
  command(:force_save, "Force save the current file", requires_buffer: true)
  command(:reload, "Reload file from disk", requires_buffer: true)
  command(:quit, "Close tab or quit", requires_buffer: true)
  command(:force_quit, "Force close tab or quit", requires_buffer: true)
  command(:close_other_tabs, "Close all tabs except the active tab", requires_buffer: true)
  command(:quit_all, "Quit the editor (all tabs)", requires_buffer: true)
  command(:force_quit_all, "Force quit the editor (all tabs)", requires_buffer: true)
  command(:abort_quit, "Abort and quit with error exit code", requires_buffer: false)
  command(:confirm_quit_yes, "Confirm quit (yes)", requires_buffer: true)
  command(:confirm_quit_no, "Confirm quit (no)", requires_buffer: true)
  command(:buffer_list, "Switch buffer", requires_buffer: true)
  command(:buffer_list_all, "Switch buffer (all)", requires_buffer: true)
  command(:buffer_next, "Next buffer", requires_buffer: true)
  command(:buffer_prev, "Previous buffer", requires_buffer: true)
  command(:kill_buffer, "Kill current buffer", requires_buffer: true)
  command(:view_messages, "Show messages in bottom panel", requires_buffer: false)
  command(:view_warnings, "Show warnings in bottom panel", requires_buffer: false)
  command(:open_config, "Open config file", requires_buffer: true)
  command(:tab_next, "Next tab", requires_buffer: true)
  command(:tab_prev, "Previous tab", requires_buffer: true)
  command(:new_buffer, "Create new empty buffer", requires_buffer: false)
  command(:reload_config, "Reload config", requires_buffer: true, execute: &reload_config/1)

  command(:alternate_file, "Switch to alternate file",
    requires_buffer: true,
    execute: &alternate_file/1
  )

  numbered_commands(:tab_goto, 1..9, "Switch to tab",
    requires_buffer: true,
    execute: &tab_goto/2
  )

  command(:cycle_line_numbers, "Cycle line number style (hybrid → absolute → relative → none)",
    requires_buffer: true,
    option_toggle:
      {:line_numbers,
       fn
         :hybrid -> :absolute
         :absolute -> :relative
         :relative -> :none
         :none -> :hybrid
       end}
  )

  command(:toggle_wrap, "Toggle word wrap",
    requires_buffer: true,
    option_toggle: :wrap
  )

  command(:toggle_invisible, "Toggle invisible characters",
    requires_buffer: true,
    option_toggle: :show_invisible
  )

  # ── Frontend dispatch ─────────────────────────────────────────────────────

  @spec frontend(state()) :: module()
  defp frontend(%{capabilities: caps}) do
    if MingaEditor.Frontend.gui?(caps), do: __MODULE__.GUI, else: __MODULE__.TUI
  end

  # In headless mode, apply highlight setup synchronously; otherwise defer.
  @spec setup_highlight_or_defer(state()) :: state()
  defp setup_highlight_or_defer(%{backend: :headless} = state) do
    state = HighlightSync.setup_for_buffer(state)
    SemanticTokenSync.request_tokens(state)
  end

  defp setup_highlight_or_defer(state) do
    send(self(), :setup_highlight)
    state
  end

  # ── :sort command ──────────────────────────────────────────────────────────

  @spec execute_sort(state(), pid(), Minga.Command.Parser.range(), [
          Minga.Command.Parser.sort_flag()
        ]) :: state()
  defp execute_sort(state, buf, range, flags) do
    total_lines = Buffer.line_count(buf)
    {start_line, end_line} = resolve_range(range, buf, total_lines)

    if start_line < 0 or end_line >= total_lines or start_line > end_line do
      EditorState.set_status(state, "Invalid range: #{start_line + 1},#{end_line + 1}")
    else
      content = Buffer.content(buf)
      lines = String.split(content, "\n")

      sorted_lines = do_sort(lines, start_line, end_line, flags)
      new_content = Enum.join(sorted_lines, "\n")

      Buffer.replace_content(buf, new_content)
      EditorState.set_status(state, "Sorted lines #{start_line + 1}-#{end_line + 1}")
    end
  end

  @spec do_sort([String.t()], non_neg_integer(), non_neg_integer(), [
          Minga.Command.Parser.sort_flag()
        ]) :: [String.t()]
  defp do_sort(lines, start_line, end_line, flags) do
    before = Enum.slice(lines, 0, start_line)
    to_sort = Enum.slice(lines, start_line, end_line - start_line + 1)
    after_lines = Enum.slice(lines, end_line + 1, length(lines))

    sorted =
      to_sort
      |> then(&apply_sort_flags(&1, flags))
      |> then(&if(:unique in flags, do: Enum.uniq(&1), else: &1))

    before ++ sorted ++ after_lines
  end

  @spec apply_sort_flags([String.t()], [Minga.Command.Parser.sort_flag()]) :: [String.t()]
  defp apply_sort_flags(lines, flags) do
    sorted = do_apply_sort_flags(lines, flags)

    if :reverse in flags do
      Enum.reverse(sorted)
    else
      sorted
    end
  end

  @spec do_apply_sort_flags([String.t()], [Minga.Command.Parser.sort_flag()]) :: [String.t()]
  defp do_apply_sort_flags(lines, flags) do
    if :numeric in flags do
      Enum.sort_by(lines, &numeric_sort_key/1)
    else
      Enum.sort(lines)
    end
  end

  @spec numeric_sort_key(String.t()) :: integer()
  defp numeric_sort_key(line) do
    case Integer.parse(String.trim_leading(line)) do
      {num, _} -> num
      :error -> 0
    end
  end

  # ── :read command ──────────────────────────────────────────────────────────

  @spec execute_read(state(), pid(), String.t()) :: state()
  defp execute_read(state, buf, filename) do
    expanded_path = Path.expand(filename)

    case File.read(expanded_path) do
      {:ok, content} ->
        cursor = Buffer.cursor(buf)
        {_line, col} = cursor

        content_to_insert =
          if col == 0 do
            content <> "\n"
          else
            "\n" <> content <> "\n"
          end

        Buffer.insert_text(buf, content_to_insert)
        EditorState.set_status(state, "Read #{expanded_path}")

      {:error, reason} ->
        EditorState.set_status(state, "Failed to read #{filename}: #{inspect(reason)}")
    end
  end

  # ── :! command ─────────────────────────────────────────────────────────────

  @spec execute_shell_command(state(), String.t()) :: state()
  defp execute_shell_command(state, command) do
    Minga.CommandOutput.run("*shell*", command)

    case Minga.CommandOutput.buffer("*shell*") do
      nil ->
        EditorState.set_status(state, "Failed to create output buffer")

      buffer_pid ->
        Commands.add_buffer(state, buffer_pid)
    end
  end

  @spec handle_file_changed_on_save(state(), GenServer.server()) :: state()
  defp handle_file_changed_on_save(state, buf) do
    case Buffer.storage(buf) do
      {:remote, node, _base_path} -> handle_remote_file_changed_on_save(state, buf, node)
      _ -> EditorState.set_status(state, "WARNING: File changed on disk. Use :w! to force save.")
    end
  catch
    :exit, _reason ->
      EditorState.set_status(state, "WARNING: File changed on disk. Use :w! to force save.")
  end

  @spec handle_remote_file_changed_on_save(state(), GenServer.server(), node()) :: state()
  defp handle_remote_file_changed_on_save(state, buf, remote_node) do
    path = Buffer.file_path(buf)

    case read_remote_conflict_content(remote_node, path) do
      {:ok, content} ->
        state
        |> EditorState.set_status(
          "File changed on server since you opened it. Reload first, keep editing, show diff, or force save."
        )
        |> PickerUI.open(MingaEditor.UI.Picker.RemoteFileConflictSource, %{
          buffer: buf,
          path: path,
          content: content
        })

      {:error, reason} ->
        EditorState.set_status(
          state,
          "File changed on server since you opened it. Reload first, or force save. Could not load remote version: #{inspect(reason)}"
        )
    end
  catch
    :exit, reason ->
      EditorState.set_status(
        state,
        "File changed on server since you opened it. Reload first, or force save. Could not inspect remote conflict: #{inspect(reason)}"
      )
  end

  @spec read_remote_conflict_content(node(), String.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  defp read_remote_conflict_content(_remote_node, nil), do: {:error, :no_file_path}

  defp read_remote_conflict_content(remote_node, path) do
    Minga.Distribution.File.read(remote_node, path,
      max_bytes: Minga.Distribution.File.max_file_bytes()
    )
  end

  # ── :global command ────────────────────────────────────────────────────────

  @spec execute_global(state(), pid(), String.t(), String.t()) :: state()
  defp execute_global(state, buf, pattern, command) do
    content = Buffer.content(buf)
    lines = String.split(content, "\n")

    matching_lines =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _idx} ->
        try do
          regex = Regex.compile!(pattern)
          Regex.match?(regex, line)
        rescue
          Regex.CompileError -> String.contains?(line, pattern)
        end
      end)

    case matching_lines do
      [] ->
        EditorState.set_status(state, "Pattern not found: #{pattern}")

      matches ->
        Enum.reduce(matches, state, fn {_line_content, idx}, acc_state ->
          Buffer.move_to(buf, {idx, 0})
          parsed_cmd = Minga.Command.Parser.parse(command)
          execute(acc_state, {:execute_ex_command, parsed_cmd})
        end)
    end
  end

  # ── :normal command ────────────────────────────────────────────────────────

  @spec execute_normal(state(), pid(), Minga.Command.Parser.range(), String.t()) :: state()
  defp execute_normal(state, buf, range, keys) do
    total_lines = Buffer.line_count(buf)
    {start_line, end_line} = resolve_range(range, buf, total_lines)

    if start_line < 0 or end_line >= total_lines or start_line > end_line do
      EditorState.set_status(state, "Invalid range: #{start_line + 1},#{end_line + 1}")
    else
      state
      |> feed_keys_on_range(buf, start_line, end_line, keys)
      |> then(fn s ->
        EditorState.set_status(s, "Normal executed on #{start_line + 1}-#{end_line + 1}")
      end)
    end
  end

  @spec feed_keys_on_range(state(), pid(), non_neg_integer(), non_neg_integer(), String.t()) ::
          state()
  defp feed_keys_on_range(state, buf, start_line, end_line, keys) do
    Enum.reduce(start_line..end_line, state, fn line_idx, acc_state ->
      Buffer.move_to(buf, {line_idx, 0})
      feed_keys_to_fsm(acc_state, keys)
    end)
  end

  @spec feed_keys_to_fsm(state(), String.t()) :: state()
  defp feed_keys_to_fsm(%{workspace: %{editing: vim}} = state, keys) do
    key_list = String.graphemes(keys)

    {final_vim, final_state} =
      Enum.reduce(key_list, {vim, state}, fn key_str, {vim_state, acc_state} ->
        key_tuple = string_to_key_tuple(key_str)

        {new_mode, commands, new_mode_state} =
          Minga.Mode.process(vim_state.mode, key_tuple, vim_state.mode_state)

        updated_vim =
          if new_mode == vim_state.mode do
            MingaEditor.VimState.set_mode_state(vim_state, new_mode_state)
          else
            MingaEditor.VimState.transition(vim_state, new_mode, new_mode_state)
          end

        updated_state =
          Enum.reduce(List.wrap(commands), acc_state, fn cmd, s ->
            Commands.execute(s, cmd)
          end)

        {updated_vim, updated_state}
      end)

    EditorState.update_workspace(final_state, &SessionState.set_editing(&1, final_vim))
  end

  @spec string_to_key_tuple(String.t()) :: Minga.Mode.key()
  defp string_to_key_tuple(key_str) do
    case key_str do
      "^" ->
        {94, 0}

      "$" ->
        {36, 0}

      "\\" ->
        {92, 0}

      c ->
        case String.to_charlist(c) do
          [code] -> {code, 0}
          _ -> {32, 0}
        end
    end
  end

  # ── Range resolution ───────────────────────────────────────────────────────

  @spec resolve_range(Minga.Command.Parser.range(), pid(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp resolve_range(:whole_buffer, _buf, total_lines) do
    {0, max(0, total_lines - 1)}
  end

  defp resolve_range(:current_line, buf, _total_lines) do
    {line, _col} = Buffer.cursor(buf)
    {line, line}
  end

  defp resolve_range(:last_line, _buf, total_lines) do
    {max(0, total_lines - 1), max(0, total_lines - 1)}
  end

  # TODO: resolve actual visual selection marks when available
  defp resolve_range(:visual, _buf, _total_lines) do
    {0, 0}
  end

  defp resolve_range({:absolute, start, finish}, _buf, _total_lines) do
    start_line = max(0, start - 1)
    end_line = max(0, finish - 1)
    {start_line, end_line}
  end
end
