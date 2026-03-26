defmodule Minga.Editor.Commands.BufferManagement do
  @moduledoc """
  Buffer management commands: save/reload/quit, buffer list/navigation/kill,
  ex-command dispatch, and line number style cycling.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Agent.Session
  alias Minga.Buffer
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
  alias Minga.Mode
  alias Minga.Mode.ToolConfirmState
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry
  alias Minga.UI.Popup.Lifecycle, as: PopupLifecycle

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  # ── Save / quit ───────────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :save) do
    state = apply_pre_save_transforms(state, buf)

    case Buffer.save(buf) do
      :ok ->
        name = Helpers.buffer_display_name(buf)

        EditorState.set_status(state, "Wrote #{name}")

      {:error, :file_changed} ->
        EditorState.set_status(state, "WARNING: File changed on disk. Use :w! to force save.")

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
    EditorState.clear_status(%{state | pending_quit: nil})
  end

  # ── Buffer navigation ─────────────────────────────────────────────────────

  def execute(state, :buffer_list) do
    PickerUI.open(state, Minga.UI.Picker.BufferSource)
  end

  def execute(state, :buffer_list_all) do
    PickerUI.open(state, Minga.UI.Picker.BufferAllSource)
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
           {Minga.Buffer, content: "", buffer_name: name}
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
    case EditorState.find_buffer_by_path(state, file_path) do
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
    buf = state.workspace.buffers.active

    if is_pid(buf) do
      try do
        Buffer.set_filetype(buf, filetype)
        send(self(), :setup_highlight)
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
    case ConfigLoader.reload() do
      :ok ->
        Minga.Editor.log_to_messages("Config reloaded")
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

  @spec switch_to_buffer(state(), non_neg_integer()) :: state()
  defp switch_to_buffer(
         %{shell_state: %{tab_bar: %TabBar{} = tb}, workspace: %{buffers: %{list: buffers}}} =
           state,
         idx
       ) do
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
  defp next_buffer(
         %{workspace: %{buffers: %{list: [_, _ | _] = buffers, active_index: idx}}} = state
       ) do
    cycle_buffer_in_tab(state, rem(idx + 1, Enum.count(buffers)))
  end

  defp next_buffer(state), do: state

  @spec prev_buffer(state()) :: state()
  defp prev_buffer(
         %{workspace: %{buffers: %{list: [_, _ | _] = buffers, active_index: idx}}} = state
       ) do
    count = Enum.count(buffers)
    cycle_buffer_in_tab(state, rem(idx - 1 + count, count))
  end

  defp prev_buffer(state), do: state

  # Cycles the buffer in the current tab. If the target buffer already
  # has its own file tab, switches to that tab instead.
  @spec cycle_buffer_in_tab(state(), non_neg_integer()) :: state()
  defp cycle_buffer_in_tab(%{shell_state: %{tab_bar: %TabBar{}}} = state, idx) do
    target_buf = Enum.at(state.workspace.buffers.list, idx)

    case find_tab_for_buffer(state.shell_state.tab_bar, target_buf) do
      nil ->
        # Buffer has no dedicated tab; switch in-place.
        EditorState.switch_buffer(state, idx)

      tab_id when tab_id == state.shell_state.tab_bar.active_id ->
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
        %{s | document: Buffer.new_document("")}
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
            %Minga.Events.BufferClosedEvent{buffer: buf, path: path}
          )

          GenServer.stop(buf, :normal)
        catch
          :exit, _ -> :ok
        end
      end

      # Free the buffer's tree-sitter parse tree in the Zig parser process.
      state = HighlightSync.close_buffer(state, buf)

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

          put_in(state.workspace.buffers, %{
            bs
            | list: new_buffers,
              active_index: new_idx,
              active: new_active
          })
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
    Minga.Editor.log_to_messages("Closed agent tab")
    state
  end

  @doc """
  Cleans up editor state after an agent session dies (`:DOWN` handler).

  The session is already dead, so no stop/unsubscribe is needed. This
  clears the spinner, agent state, tab session/status, and agent group.
  """
  @spec handle_agent_session_down(state(), pid(), term()) :: state()
  def handle_agent_session_down(
        %{shell: Minga.Shell.Board} = state,
        session_pid,
        reason
      ) do
    card_status = if reason in [:normal, :shutdown], do: :done, else: :errored
    board = state.shell_state

    # Find and update the card with this session
    board =
      case Enum.find(board.cards, fn {_id, card} -> card.session == session_pid end) do
        {card_id, _card} ->
          Minga.Shell.Board.State.update_card(board, card_id, fn card ->
            Minga.Shell.Board.Card.set_status(card, card_status)
          end)

        nil ->
          board
      end

    state = %{state | shell_state: board}
    state = AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)
    state = AgentAccess.update_agent(state, &AgentState.clear_session/1)

    msg =
      if reason in [:normal, :shutdown],
        do: "Agent session ended",
        else: "Agent session crashed"

    EditorState.set_status(state, msg)
  end

  def handle_agent_session_down(
        %{shell_state: %{tab_bar: %TabBar{}}} = state,
        session_pid,
        reason
      ) do
    tab_status = if reason in [:normal, :shutdown], do: :idle, else: :error
    state = scrub_agent_tab_state(state, session_pid, tab_status)

    msg =
      if reason in [:normal, :shutdown],
        do: "Agent session ended",
        else: "Agent session crashed (SPC a n to restart)"

    EditorState.set_status(state, msg)
  end

  # Shared state cleanup for agent sessions: stops spinner, clears
  # agent state session, clears Tab.session/agent_status, removes group.
  @spec scrub_agent_tab_state(state(), pid() | nil, Tab.agent_status()) :: state()
  defp scrub_agent_tab_state(state, session, tab_status \\ :idle) do
    state = AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)
    state = AgentAccess.update_agent(state, &AgentState.clear_session/1)

    # Clear session and status on any tab that referenced this session.
    state =
      if session do
        clear_session_from_tabs(state, session, tab_status)
      else
        state
      end

    # Remove the agent's group from the tab bar.
    case session && TabBar.find_group_by_session(state.shell_state.tab_bar, session) do
      %{id: group_id} ->
        EditorState.set_tab_bar(state, TabBar.remove_group(state.shell_state.tab_bar, group_id))

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
    |> then(fn s -> put_in(s.workspace.keymap_scope, :editor) end)
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
  # Checks whether a quit should be confirmed (dirty buffers + confirm_quit enabled).
  # If confirmation is needed, sets `pending_quit` and a status message.
  # Otherwise, proceeds with the quit immediately.
  @spec maybe_confirm_quit(state(), :quit | :quit_all) :: state()
  defp maybe_confirm_quit(state, kind) do
    if confirm_quit_enabled?() and any_buffer_dirty?(state) do
      EditorState.set_status(
        %{state | pending_quit: kind},
        "Modified buffers exist. Really quit? (y/n)"
      )
    else
      case kind do
        :quit -> close_tab_or_quit(state)
        :quit_all -> shutdown_editor(state)
      end
    end
  end

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

  @spec confirm_quit_enabled?() :: boolean()
  defp confirm_quit_enabled? do
    ConfigOptions.get(:confirm_quit)
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
  defp close_tab_or_quit(%{shell_state: %{tab_bar: %TabBar{tabs: [_, _ | _]}}} = state) do
    case EditorState.active_tab_kind(state) do
      :agent -> close_agent_tab(state)
      _ -> close_file_tab(state)
    end
  end

  # Last tab: replace with an empty buffer instead of quitting.
  # Matches VS Code/Zed behavior where closing the last tab leaves
  # an empty editor, not an exited process.
  defp close_tab_or_quit(%{shell_state: %{tab_bar: %TabBar{tabs: [only]}}} = state) do
    # For agent tabs, clean up the session first (no tab navigation;
    # cleanup_agent_session is pure resource teardown).
    state = if only.kind == :agent, do: cleanup_agent_session(state), else: state

    {:ok, buf} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {Minga.Buffer, content: "", buffer_name: "[new]"}
      )

    # add_buffer creates a new file tab (for agent tabs, via
    # add_buffer_as_new_tab which resets keymap_scope to :editor
    # and resets the agent UI). For file tabs it replaces in place.
    state = EditorState.add_buffer(state, buf)

    # Now we have 2 tabs; remove the old one.
    {:ok, tb} = TabBar.remove(state.shell_state.tab_bar, only.id)
    EditorState.set_tab_bar(state, tb)
  end

  defp close_tab_or_quit(state), do: shutdown_editor(state)

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

  # Closes the current file tab without killing the buffer. The buffer
  # stays in the buffer pool (matching Neovim's `:q` which closes the
  # window but leaves the buffer in the background buffer list).
  @spec close_file_tab(state()) :: state()
  defp close_file_tab(%{shell_state: %{tab_bar: %TabBar{}}} = state) do
    active_tab = EditorState.active_tab(state)
    label = if active_tab, do: active_tab.label, else: "tab"
    Minga.Editor.log_to_messages("Closed: #{label}")

    state
    |> remove_current_tab()
    |> restore_active_tab_context()
  end

  @spec remove_current_tab(state()) :: state()
  defp remove_current_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    case TabBar.remove(tb, tb.active_id) do
      {:ok, new_tb} -> EditorState.set_tab_bar(state, new_tb)
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

    case spec do
      nil ->
        state

      _ ->
        command = spec |> String.split() |> List.first()

        if System.find_executable(command) do
          run_formatter_with_spec(state, buf, spec, buf_name)
        else
          # Formatter binary not found; queue a tool prompt if a recipe exists
          queue_formatter_tool_prompt(state, command)
        end
    end
  end

  @spec run_formatter_with_spec(state(), pid(), String.t(), String.t()) :: state()
  defp run_formatter_with_spec(state, buf, spec, buf_name) do
    case Minga.Editing.format(Buffer.content(buf), spec) do
      {:ok, formatted} ->
        Buffer.replace_content(buf, formatted)
        Minga.Editor.log_to_messages("Format-on-save: #{buf_name}")
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
        %{
          state
          | workspace: %{
              state.workspace
              | windows: %{state.workspace.windows | active: popup_window_id}
            }
        }

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
           {Minga.Buffer, content: "", buffer_name: "[new 1]"}
         ) do
      {:ok, new_buf} ->
        %{
          state
          | workspace: %{
              state.workspace
              | buffers: %{bs | list: [new_buf], active_index: 0, active: new_buf}
            }
        }
        |> EditorState.sync_active_window_buffer()

      {:error, _} ->
        %{
          state
          | workspace: %{
              state.workspace
              | buffers: %{bs | list: [], active_index: 0, active: nil}
            }
        }
    end
  end

  @impl Minga.Command.Provider
  def __commands__ do
    standard = [
      %Minga.Command{
        name: :save,
        description: "Save the current file",
        requires_buffer: true,
        execute: fn state -> execute(state, :save) end
      },
      %Minga.Command{
        name: :force_save,
        description: "Force save the current file",
        requires_buffer: true,
        execute: fn state -> execute(state, :force_save) end
      },
      %Minga.Command{
        name: :reload,
        description: "Reload file from disk",
        requires_buffer: true,
        execute: fn state -> execute(state, :reload) end
      },
      %Minga.Command{
        name: :quit,
        description: "Close tab or quit",
        requires_buffer: true,
        execute: fn state -> execute(state, :quit) end
      },
      %Minga.Command{
        name: :force_quit,
        description: "Force close tab or quit",
        requires_buffer: true,
        execute: fn state -> execute(state, :force_quit) end
      },
      %Minga.Command{
        name: :quit_all,
        description: "Quit the editor (all tabs)",
        requires_buffer: true,
        execute: fn state -> execute(state, :quit_all) end
      },
      %Minga.Command{
        name: :force_quit_all,
        description: "Force quit the editor (all tabs)",
        requires_buffer: true,
        execute: fn state -> execute(state, :force_quit_all) end
      },
      %Minga.Command{
        name: :confirm_quit_yes,
        description: "Confirm quit (yes)",
        requires_buffer: true,
        execute: fn state -> execute(state, :confirm_quit_yes) end
      },
      %Minga.Command{
        name: :confirm_quit_no,
        description: "Confirm quit (no)",
        requires_buffer: true,
        execute: fn state -> execute(state, :confirm_quit_no) end
      },
      %Minga.Command{
        name: :buffer_list,
        description: "Switch buffer",
        requires_buffer: true,
        execute: fn state -> execute(state, :buffer_list) end
      },
      %Minga.Command{
        name: :buffer_list_all,
        description: "Switch buffer (all)",
        requires_buffer: true,
        execute: fn state -> execute(state, :buffer_list_all) end
      },
      %Minga.Command{
        name: :buffer_next,
        description: "Next buffer",
        requires_buffer: true,
        execute: fn state -> execute(state, :buffer_next) end
      },
      %Minga.Command{
        name: :buffer_prev,
        description: "Previous buffer",
        requires_buffer: true,
        execute: fn state -> execute(state, :buffer_prev) end
      },
      %Minga.Command{
        name: :kill_buffer,
        description: "Kill current buffer",
        requires_buffer: true,
        execute: fn state -> execute(state, :kill_buffer) end
      },
      %Minga.Command{
        name: :view_messages,
        description: "Show messages in bottom panel",
        requires_buffer: false,
        execute: fn state -> execute(state, :view_messages) end
      },
      %Minga.Command{
        name: :view_warnings,
        description: "Show warnings in bottom panel",
        requires_buffer: false,
        execute: fn state -> execute(state, :view_warnings) end
      },
      %Minga.Command{
        name: :open_config,
        description: "Open config file",
        requires_buffer: true,
        execute: fn state -> execute(state, :open_config) end
      },
      %Minga.Command{
        name: :tab_next,
        description: "Next tab",
        requires_buffer: true,
        execute: fn state -> execute(state, :tab_next) end
      },
      %Minga.Command{
        name: :tab_prev,
        description: "Previous tab",
        requires_buffer: true,
        execute: fn state -> execute(state, :tab_prev) end
      },
      %Minga.Command{
        name: :new_buffer,
        description: "Create new empty buffer",
        requires_buffer: false,
        execute: fn state -> execute(state, :new_buffer) end
      },
      %Minga.Command{
        name: :reload_config,
        description: "Reload config",
        requires_buffer: true,
        execute: &reload_config/1
      },
      %Minga.Command{
        name: :alternate_file,
        description: "Switch to alternate file",
        requires_buffer: true,
        execute: &alternate_file/1
      }
    ]

    tabs =
      for n <- 1..9 do
        cmd = String.to_atom("tab_goto_#{n}")

        %Minga.Command{
          name: cmd,
          description: "Switch to tab #{n}",
          requires_buffer: true,
          execute: fn state -> tab_goto(state, cmd) end
        }
      end

    scoped = [
      %Minga.Command{
        name: :cycle_line_numbers,
        description: "Cycle line number style (hybrid → absolute → relative → none)",
        requires_buffer: true,
        execute: fn state -> execute(state, :cycle_line_numbers) end,
        scope: %{
          option: :line_numbers,
          toggle: fn
            :hybrid -> :absolute
            :absolute -> :relative
            :relative -> :none
            :none -> :hybrid
          end
        }
      },
      %Minga.Command{
        name: :toggle_wrap,
        description: "Toggle word wrap",
        requires_buffer: true,
        execute: fn state -> execute(state, :toggle_wrap) end,
        scope: %{option: :wrap, toggle: true}
      }
    ]

    standard ++ tabs ++ scoped
  end

  # ── Frontend dispatch ─────────────────────────────────────────────────────

  @spec frontend(state()) :: module()
  defp frontend(%{capabilities: caps}) do
    if Minga.Frontend.gui?(caps), do: __MODULE__.GUI, else: __MODULE__.TUI
  end
end
