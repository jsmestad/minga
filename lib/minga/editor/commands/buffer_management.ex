defmodule Minga.Editor.Commands.BufferManagement do
  @moduledoc """
  Buffer management commands: save/reload/quit, buffer list/navigation/kill,
  ex-command dispatch, and line number style cycling.
  """

  alias Minga.Agent.Session
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
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Window
  alias Minga.Formatter
  alias Minga.Mode
  alias Minga.Popup.Lifecycle, as: PopupLifecycle

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  # ── Save / quit ───────────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :save) do
    state = apply_pre_save_transforms(state, buf)

    case BufferServer.save(buf) do
      :ok ->
        name = Helpers.buffer_display_name(buf)

        %{state | status_msg: "Wrote #{name}"}
        |> refresh_tree_git_status()

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
    if last_tab?(state) do
      maybe_confirm_quit(state, :quit)
    else
      close_tab_or_quit(state)
    end
  end

  def execute(state, :force_quit), do: close_tab_or_quit(state)
  def execute(state, :quit_all), do: maybe_confirm_quit(state, :quit_all)
  def execute(state, :force_quit_all), do: shutdown_editor(state)

  def execute(%{pending_quit: kind} = state, :confirm_quit_yes) when kind != nil do
    state = %{state | pending_quit: nil}

    case kind do
      :quit -> close_tab_or_quit(state)
      :quit_all -> shutdown_editor(state)
    end
  end

  def execute(state, :confirm_quit_no) do
    %{state | pending_quit: nil, status_msg: nil}
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
  def execute(state, :tab_next), do: next_tab(state)
  def execute(state, :tab_prev), do: prev_tab(state)

  def execute(state, :kill_buffer) do
    case EditorState.active_tab_kind(state) do
      :agent -> close_agent_tab(state)
      _ -> remove_current_buffer(state)
    end
  end

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
        Minga.Log.error(:editor, "Failed to create buffer: #{inspect(reason)}")
        state
    end
  end

  def execute(%{buffers: %{messages: nil}} = state, :view_messages) do
    %{state | status_msg: "No messages buffer"}
  end

  def execute(%{buffers: %{messages: msg_buf}} = state, :view_messages) do
    open_special_buffer(state, "*Messages*", msg_buf)
  end

  def execute(%{buffers: %{warnings: nil}} = state, :view_warnings) do
    %{state | status_msg: "No warnings buffer"}
  end

  def execute(%{buffers: %{warnings: warn_buf}} = state, :view_warnings) do
    open_special_buffer(state, "*Warnings*", warn_buf)
  end

  def execute(state, {:open_special_buffer, buffer_name, buffer_pid})
      when is_binary(buffer_name) and is_pid(buffer_pid) do
    open_special_buffer(state, buffer_name, buffer_pid)
  end

  # ── Line number style ─────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :cycle_line_numbers) when is_pid(buf) do
    current = BufferServer.get_option(buf, :line_numbers)

    next =
      case current do
        :hybrid -> :absolute
        :absolute -> :relative
        :relative -> :none
        :none -> :hybrid
      end

    BufferServer.set_option(buf, :line_numbers, next)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :toggle_wrap) when is_pid(buf) do
    current = BufferServer.get_option(buf, :wrap)
    BufferServer.set_option(buf, :wrap, !current)
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

  def execute(state, {:execute_ex_command, {:force_quit, []}}),
    do: execute(state, :force_quit)

  def execute(state, {:execute_ex_command, {:quit_all, []}}),
    do: execute(state, :quit_all)

  def execute(state, {:execute_ex_command, {:force_quit_all, []}}),
    do: execute(state, :force_quit_all)

  def execute(state, {:execute_ex_command, {:save_quit, []}}) do
    state |> execute(:save) |> close_tab_or_quit()
  end

  def execute(state, {:execute_ex_command, {:save_quit_all, []}}) do
    state |> save_all_buffers() |> shutdown_editor()
  end

  def execute(state, {:execute_ex_command, {:edit, file_path}}) do
    case find_buffer_by_path(state, file_path) do
      nil ->
        case Commands.start_buffer(file_path) do
          {:ok, pid} ->
            Commands.add_buffer(state, pid)

          {:error, reason} ->
            Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
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

  def execute(%{buffers: %{active: buf}} = state, {:execute_ex_command, {:set, :number}})
      when is_pid(buf) do
    BufferServer.set_option(buf, :line_numbers, :absolute)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, {:execute_ex_command, {:set, :nonumber}})
      when is_pid(buf) do
    BufferServer.set_option(buf, :line_numbers, :none)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, {:execute_ex_command, {:set, :relativenumber}})
      when is_pid(buf) do
    current = BufferServer.get_option(buf, :line_numbers)

    next =
      case current do
        :absolute -> :hybrid
        _ -> :relative
      end

    BufferServer.set_option(buf, :line_numbers, next)
    state
  end

  def execute(
        %{buffers: %{active: buf}} = state,
        {:execute_ex_command, {:set, :norelativenumber}}
      )
      when is_pid(buf) do
    current = BufferServer.get_option(buf, :line_numbers)

    next =
      case current do
        :hybrid -> :absolute
        _ -> :none
      end

    BufferServer.set_option(buf, :line_numbers, next)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, {:execute_ex_command, {:set, :wrap}})
      when is_pid(buf) do
    BufferServer.set_option(buf, :wrap, true)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, {:execute_ex_command, {:set, :nowrap}})
      when is_pid(buf) do
    BufferServer.set_option(buf, :wrap, false)
    state
  end

  # ── :setglobal — writes to the global Options agent ───────────────────────

  def execute(state, {:execute_ex_command, {:setglobal, :number}}) do
    ConfigOptions.set(:line_numbers, :absolute)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :nonumber}}) do
    ConfigOptions.set(:line_numbers, :none)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :relativenumber}}) do
    current = ConfigOptions.get(:line_numbers)

    next =
      case current do
        :absolute -> :hybrid
        _ -> :relative
      end

    ConfigOptions.set(:line_numbers, next)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :norelativenumber}}) do
    current = ConfigOptions.get(:line_numbers)

    next =
      case current do
        :hybrid -> :absolute
        _ -> :none
      end

    ConfigOptions.set(:line_numbers, next)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :wrap}}) do
    ConfigOptions.set(:wrap, true)
    state
  end

  def execute(state, {:execute_ex_command, {:setglobal, :nowrap}}) do
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
      {:error, message} -> %{state | status_msg: message}
    end
  end

  def execute(state, {:execute_ex_command, {:unknown, raw}}) do
    Minga.Log.debug(:editor, "Unknown ex command: #{raw}")
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

    case Commands.start_buffer(config_path) do
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
    buf = state.buffers.active

    if is_pid(buf) and Process.alive?(buf) do
      BufferServer.set_filetype(buf, filetype)
      send(self(), :setup_highlight)
      %{state | status_msg: "Language: #{filetype}"}
    else
      %{state | status_msg: "No active buffer"}
    end
  end

  # ── Private buffer helpers ────────────────────────────────────────────────

  @spec switch_to_buffer(state(), non_neg_integer()) :: state()
  @spec switch_to_buffer(state(), non_neg_integer()) :: state()
  defp switch_to_buffer(%{tab_bar: %TabBar{} = tb, buffers: %{list: buffers}} = state, idx) do
    target_buf = Enum.at(buffers, idx)

    # Find the file tab whose context holds this buffer
    case find_tab_for_buffer(tb, target_buf) do
      nil ->
        # No tab found, fall back to index-based switching
        EditorState.switch_buffer(state, idx)

      tab_id ->
        EditorState.switch_tab(state, tab_id)
    end
  end

  defp switch_to_buffer(state, idx), do: EditorState.switch_buffer(state, idx)

  alias Minga.Editor.State.Tab

  @spec find_tab_for_buffer(TabBar.t(), pid() | nil) :: Tab.id() | nil
  defp find_tab_for_buffer(_tb, nil), do: nil

  defp find_tab_for_buffer(%TabBar{tabs: tabs}, target_buf) do
    Enum.find_value(tabs, fn
      %{kind: :file, id: id, context: %{active_buffer: ^target_buf}} -> id
      _ -> nil
    end)
  end

  @spec next_buffer(state()) :: state()
  defp next_buffer(%{buffers: %{list: [_, _ | _] = buffers, active_index: idx}} = state) do
    cycle_buffer_in_tab(state, rem(idx + 1, Enum.count(buffers)))
  end

  defp next_buffer(state), do: state

  @spec prev_buffer(state()) :: state()
  defp prev_buffer(%{buffers: %{list: [_, _ | _] = buffers, active_index: idx}} = state) do
    count = Enum.count(buffers)
    cycle_buffer_in_tab(state, rem(idx - 1 + count, count))
  end

  defp prev_buffer(state), do: state

  # Cycles the buffer in the current tab. If the target buffer already
  # has its own file tab, switches to that tab instead.
  @spec cycle_buffer_in_tab(state(), non_neg_integer()) :: state()
  defp cycle_buffer_in_tab(%{tab_bar: %TabBar{}} = state, idx) do
    target_buf = Enum.at(state.buffers.list, idx)

    case find_tab_for_buffer(state.tab_bar, target_buf) do
      nil ->
        # Buffer has no dedicated tab; switch in-place.
        EditorState.switch_buffer(state, idx)

      tab_id when tab_id == state.tab_bar.active_id ->
        # Buffer's tab is the current tab; switch in-place.
        EditorState.switch_buffer(state, idx)

      tab_id ->
        # Buffer lives in another tab; switch to it.
        EditorState.switch_tab(state, tab_id)
    end
  end

  defp cycle_buffer_in_tab(state, idx) do
    EditorState.switch_buffer(state, idx)
  end

  @spec next_tab(state()) :: state()
  defp next_tab(%{tab_bar: %TabBar{} = tb} = state) do
    next_tb = TabBar.next(tb)

    if next_tb.active_id != tb.active_id do
      EditorState.switch_tab(state, next_tb.active_id)
    else
      state
    end
  end

  defp next_tab(state), do: state

  @spec prev_tab(state()) :: state()
  defp prev_tab(%{tab_bar: %TabBar{} = tb} = state) do
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
         %{buffers: %{list: [_ | _] = buffers, active_index: idx} = bs} = state
       ) do
    buf = Enum.at(buffers, idx)

    # Check if persistent — if so, recreate instead of removing
    if buf && Process.alive?(buf) && BufferServer.persistent?(buf) do
      # Clear buffer content instead of killing it
      :sys.replace_state(buf, fn s ->
        %{s | document: Document.new("")}
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

      # Remove the current tab from the tab bar (if present).
      # TabBar.remove handles neighbor selection.
      state = remove_current_tab(state)

      case new_buffers do
        [] ->
          create_fallback_buffer(state, bs)

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

  @spec close_agent_tab(state()) :: state()
  defp close_agent_tab(%{tab_bar: %TabBar{}} = state) do
    # Stop spinner timer before it leaks
    state = AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)

    # Unsubscribe and stop the agent session if running
    session = AgentAccess.session(state)

    if session do
      try do
        Session.unsubscribe(session)
      catch
        :exit, _ -> :ok
      end

      if Process.alive?(session) do
        try do
          GenServer.stop(session, :normal)
        catch
          :exit, _ -> :ok
        end
      end
    end

    Minga.Editor.log_to_messages("Closed agent tab")

    # Find a file tab to switch to
    case TabBar.most_recent_of_kind(state.tab_bar, :file) do
      %Tab{} ->
        # Deactivate agentic view and switch to the file tab.
        # restore_active_tab_context will set up the correct surface
        # for the file tab we're switching to.
        %{state | keymap_scope: :editor}
        |> remove_current_tab()
        |> restore_active_tab_context()

      nil ->
        # No file tabs left, just remove the agent tab
        remove_current_tab(state)
    end
  end

  defp close_agent_tab(state), do: state

  # Closes the current tab if multiple tabs are open, or exits the editor
  # if this is the last tab. Mirrors Neovim's `:q` hierarchy: close the
  # smallest container first, only exit when nothing is left to close.
  #
  # For file tabs, this closes the tab without killing the buffer (matching
  # Neovim where `:q` closes the window but the buffer stays in memory).
  # For agent tabs, session cleanup is needed so we delegate to close_agent_tab.
  # Checks whether a quit should be confirmed (dirty buffers + confirm_quit enabled).
  # If confirmation is needed, sets `pending_quit` and a status message.
  # Otherwise, proceeds with the quit immediately.
  @spec maybe_confirm_quit(state(), :quit | :quit_all) :: state()
  defp maybe_confirm_quit(state, kind) do
    if confirm_quit_enabled?() and any_buffer_dirty?(state) do
      %{state | pending_quit: kind, status_msg: "Modified buffers exist. Really quit? (y/n)"}
    else
      case kind do
        :quit -> close_tab_or_quit(state)
        :quit_all -> shutdown_editor(state)
      end
    end
  end

  @spec any_buffer_dirty?(state()) :: boolean()
  defp any_buffer_dirty?(state) do
    Enum.any?(state.buffers.list, fn pid ->
      Process.alive?(pid) and BufferServer.dirty?(pid)
    end)
  end

  @spec confirm_quit_enabled?() :: boolean()
  defp confirm_quit_enabled? do
    ConfigOptions.get(:confirm_quit)
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  @spec last_tab?(state()) :: boolean()
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

  defp last_tab?(%{tab_bar: %TabBar{tabs: [_]}}), do: true
  defp last_tab?(%{tab_bar: nil}), do: true
  defp last_tab?(_state), do: false

  @spec close_tab_or_quit(state()) :: state()
  defp close_tab_or_quit(%{tab_bar: %TabBar{tabs: [_, _ | _]}} = state) do
    case EditorState.active_tab_kind(state) do
      :agent -> close_agent_tab(state)
      _ -> close_file_tab(state)
    end
  end

  defp close_tab_or_quit(state), do: shutdown_editor(state)

  # Saves all dirty buffers in the buffer list. Called by :wqa before
  # shutting down. Returns state unchanged (side-effectual only).
  @spec save_all_buffers(state()) :: state()
  defp save_all_buffers(state) do
    Enum.each(state.buffers.list, fn buf ->
      if Process.alive?(buf) and BufferServer.dirty?(buf) do
        BufferServer.save(buf)
      end
    end)

    state
  end

  # Exits the editor. Single exit point so shutdown cleanup (flush buffers,
  # save session, etc.) can be added in one place.
  @spec shutdown_editor(state()) :: state()
  defp shutdown_editor(state) do
    System.stop(0)
    state
  end

  # Closes the current file tab without killing the buffer. The buffer
  # stays in the buffer pool (matching Neovim's `:q` which closes the
  # window but leaves the buffer in the background buffer list).
  @spec close_file_tab(state()) :: state()
  defp close_file_tab(%{tab_bar: %TabBar{}} = state) do
    active_tab = EditorState.active_tab(state)
    label = if active_tab, do: active_tab.label, else: "tab"
    Minga.Editor.log_to_messages("Closed: #{label}")

    state
    |> remove_current_tab()
    |> restore_active_tab_context()
  end

  @spec remove_current_tab(state()) :: state()
  defp remove_current_tab(%{tab_bar: %TabBar{} = tb} = state) do
    case TabBar.remove(tb, tb.active_id) do
      {:ok, new_tb} -> %{state | tab_bar: new_tb}
      :last_tab -> state
    end
  end

  defp remove_current_tab(state), do: state

  # Restores the now-active tab's snapshotted context into live editor state.
  # Called after removing a tab to switch the editor to the neighbor tab's
  # buffers, windows, viewport, etc. No-op for brand-new tabs with no snapshot.
  @spec restore_active_tab_context(state()) :: state()
  defp restore_active_tab_context(state) do
    case EditorState.active_tab(state) do
      %Tab{context: context} when is_map(context) and map_size(context) > 0 ->
        EditorState.restore_tab_context(state, context)

      _ ->
        state
    end
  end

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
    state = maybe_format_on_save(state, buf, nil)
    apply_whitespace_transforms(buf)
    state
  end

  @spec maybe_format_on_save(state(), pid(), atom()) :: state()
  defp maybe_format_on_save(state, buf, _filetype) do
    if BufferServer.get_option(buf, :format_on_save) do
      run_format_on_save(state, buf)
    else
      state
    end
  end

  @spec run_format_on_save(state(), pid()) :: state()
  defp run_format_on_save(state, buf) do
    file_path = BufferServer.file_path(buf)
    filetype = BufferServer.filetype(buf)
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
        Minga.Log.warning(:editor, "Format-on-save failed: #{buf_name} (#{msg})")
        state
    end
  end

  @spec apply_whitespace_transforms(pid()) :: :ok
  defp apply_whitespace_transforms(buf) do
    needs_trim = BufferServer.get_option(buf, :trim_trailing_whitespace)
    needs_final_newline = BufferServer.get_option(buf, :insert_final_newline)

    if needs_trim or needs_final_newline do
      content = BufferServer.content(buf)
      transformed = Formatter.apply_save_transforms(content, needs_trim, needs_final_newline)

      if transformed != content do
        BufferServer.replace_content(buf, transformed)
      end
    end

    :ok
  end

  # Opens a special buffer (like *Messages* or *Warnings*) as a popup if a
  # matching popup rule exists, otherwise falls back to normal buffer switching.
  # If the buffer is already open in a popup, toggles it closed.
  @spec open_special_buffer(state(), String.t(), pid()) :: state()
  defp open_special_buffer(state, buffer_name, buffer_pid) do
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
        %{state | windows: %{state.windows | active: popup_window_id}}

      :none ->
        state
    end
  end

  @spec switch_or_add_buffer(state(), pid()) :: state()
  defp switch_or_add_buffer(state, buffer_pid) do
    idx = Enum.find_index(state.buffers.list, &(&1 == buffer_pid))

    case idx do
      nil -> Commands.add_buffer(state, buffer_pid)
      i -> switch_to_buffer(state, i)
    end
  end

  # Finds an existing popup window displaying the given buffer pid.
  @spec find_popup_for_buffer(state(), pid()) :: {:ok, Window.id()} | :none
  defp find_popup_for_buffer(state, buffer_pid) do
    result =
      Enum.find(state.windows.map, fn {_id, window} ->
        Window.popup?(window) and window.buffer == buffer_pid
      end)

    case result do
      {id, _window} -> {:ok, id}
      nil -> :none
    end
  end

  # Refreshes git status in the file tree (if open) after file operations.
  @spec refresh_tree_git_status(EditorState.t()) :: EditorState.t()
  defp refresh_tree_git_status(%{file_tree: %{tree: nil}} = state), do: state

  defp refresh_tree_git_status(%{file_tree: %{tree: tree}} = state) do
    updated_tree = Minga.FileTree.refresh_git_status(tree)
    put_in(state.file_tree.tree, updated_tree)
  end

  # Creates an empty buffer when the last buffer is killed.
  # Dashboard is disabled pending rewrite as a special buffer.
  @spec create_fallback_buffer(state(), EditorState.Buffers.t()) :: state()
  defp create_fallback_buffer(state, bs) do
    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {BufferServer, content: "", buffer_name: "[new 1]"}
         ) do
      {:ok, new_buf} ->
        %{state | buffers: %{bs | list: [new_buf], active_index: 0, active: new_buf}}
        |> EditorState.sync_active_window_buffer()

      {:error, _} ->
        %{state | buffers: %{bs | list: [], active_index: 0, active: nil}}
    end
  end
end
