defmodule Minga.Command.Registry do
  @moduledoc """
  Agent-based registry for named editor commands.

  Commands are stored by name (atom) and can be registered, looked up,
  and listed. Built-in commands are registered on start.

  ## Usage

      {:ok, _pid} = Minga.Command.Registry.start_link(name: MyRegistry)
      {:ok, cmd} = Minga.Command.Registry.lookup(MyRegistry, :save)
  """

  use Agent

  alias Minga.Command

  @typedoc "Agent name or pid for the registry."
  @type server :: Agent.name()

  # Internal registry state — map from command name atom to Command.t()
  @typep state :: %{atom() => Command.t()}

  # Built-in command name + description pairs.
  # Execute functions are looked up at runtime to avoid embedding anonymous
  # functions in module attributes (which Elixir cannot escape at compile time).
  @built_in_specs [
    {:save, "Save the current file"},
    {:quit, "Close tab or quit"},
    {:force_quit, "Force close tab or quit"},
    {:quit_all, "Quit the editor (all tabs)"},
    {:force_quit_all, "Force quit the editor (all tabs)"},
    {:move_left, "Move cursor left"},
    {:move_right, "Move cursor right"},
    {:move_up, "Move cursor up"},
    {:move_down, "Move cursor down"},
    {:delete_before, "Delete character before cursor (backspace)"},
    {:delete_at, "Delete character at cursor (delete)"},
    {:delete_chars_at, "Delete character(s) at cursor and yank (x)"},
    {:delete_chars_before, "Delete character(s) before cursor and yank (X)"},
    {:insert_newline, "Insert a newline at cursor"},
    {:undo, "Undo the last change"},
    {:redo, "Redo the last undone change"},
    {:find_file, "Find file in project"},
    {:search_project, "Search across project files"},
    {:buffer_list, "Switch buffer"},
    {:buffer_list_all, "Switch buffer (all)"},
    {:buffer_next, "Next buffer"},
    {:buffer_prev, "Previous buffer"},
    {:kill_buffer, "Kill current buffer"},
    {:tab_next, "Next tab"},
    {:tab_prev, "Previous tab"},
    {:cycle_agent_tabs, "Cycle agent tabs (opens split if none)"},
    {:tab_goto_1, "Switch to tab 1"},
    {:tab_goto_2, "Switch to tab 2"},
    {:tab_goto_3, "Switch to tab 3"},
    {:tab_goto_4, "Switch to tab 4"},
    {:tab_goto_5, "Switch to tab 5"},
    {:tab_goto_6, "Switch to tab 6"},
    {:tab_goto_7, "Switch to tab 7"},
    {:tab_goto_8, "Switch to tab 8"},
    {:tab_goto_9, "Switch to tab 9"},
    {:view_messages, "View *Messages* buffer"},
    {:view_warnings, "View *Warnings* buffer"},
    {:view_scratch, "Switch to *scratch* buffer"},
    {:new_buffer, "Create new empty buffer"},
    {:command_palette, "Execute command"},
    {:theme_picker, "Pick theme"},
    {:delete_line, "Delete current line"},
    {:yank_line, "Yank current line"},
    {:paste_after, "Paste after cursor"},
    {:paste_before, "Paste before cursor"},
    {:half_page_down, "Scroll half page down"},
    {:half_page_up, "Scroll half page up"},
    {:page_down, "Scroll page down"},
    {:page_up, "Scroll page up"},
    {:cycle_line_numbers, "Cycle line number style (hybrid → absolute → relative → none)"},
    {:toggle_wrap, "Toggle word wrap"},
    {:diagnostics_list, "List buffer diagnostics"},
    {:next_diagnostic, "Jump to next diagnostic"},
    {:prev_diagnostic, "Jump to previous diagnostic"},
    {:lsp_info, "Show LSP server status"},
    {:open_config, "Open config file"},
    {:reload_config, "Reload config"},
    {:format_buffer, "Format buffer"},
    {:goto_definition, "Go to definition"},
    {:alternate_file, "Switch to alternate file"},
    {:hover, "Hover documentation"},
    {:next_git_hunk, "Next git hunk"},
    {:prev_git_hunk, "Previous git hunk"},
    {:git_stage_hunk, "Stage hunk"},
    {:git_revert_hunk, "Revert hunk"},
    {:git_preview_hunk, "Preview hunk"},
    {:git_blame_line, "Blame line"},
    {:toggle_comment_line, "Toggle comment on line"},
    {:toggle_comment_selection, "Toggle comment on selection"},
    {:toggle_agent_panel, "Toggle AI agent panel"},
    {:toggle_agentic_view, "Toggle agent split pane"},
    {:agent_abort, "Stop AI agent"},
    {:agent_new_session, "New AI agent session"},
    {:agent_pick_model, "Pick AI agent model"},
    {:agent_cycle_model, "Cycle AI agent model"},
    {:agent_summarize, "Summarize session to context artifact"},
    {:agent_cycle_thinking, "Cycle AI thinking level"},
    {:fold_toggle, "Toggle fold at cursor (za)"},
    {:fold_close, "Close fold at cursor (zc)"},
    {:fold_open, "Open fold at cursor (zo)"},
    {:fold_close_all, "Close all folds (zM)"},
    {:fold_open_all, "Open all folds (zR)"}
  ]

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the command registry as a named Agent.

  ## Options

  * `:name` — the name to register the Agent under (default: `#{__MODULE__}`)
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    Agent.start_link(fn -> build_initial_state() end, name: name)
  end

  @doc """
  Registers a command with the given name, description, and execute function.

  If a command with the same name already exists it is overwritten.
  """
  @spec register(server(), atom(), String.t(), function()) :: :ok
  def register(server, name, description, execute)
      when is_atom(name) and is_binary(description) and is_function(execute) do
    cmd = %Command{name: name, description: description, execute: execute}
    Agent.update(server, &Map.put(&1, name, cmd))
  end

  @doc """
  Looks up a command by name.

  Returns `{:ok, command}` if found, `:error` otherwise.
  """
  @spec lookup(server(), atom()) :: {:ok, Command.t()} | :error
  def lookup(server, name) when is_atom(name) do
    case Agent.get(server, &Map.fetch(&1, name)) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  end

  @doc """
  Returns all registered commands as a list.
  """
  @spec all(server()) :: [Command.t()]
  def all(server) do
    Agent.get(server, &Map.values(&1))
  end

  @doc """
  Resets the registry to built-in commands only.

  Removes all user-registered commands and re-registers the defaults.
  Used by hot reload to clear stale user commands before re-evaluating config.
  """
  @spec reset() :: :ok
  @spec reset(server()) :: :ok
  def reset, do: reset(__MODULE__)

  def reset(server) do
    Agent.update(server, fn _ -> build_initial_state() end)
  end

  # ── Built-in execute functions ───────────────────────────────────────────────
  # Named private functions so they can be captured with &__MODULE__.name/arity.

  @spec execute_save(map()) :: map()
  defp execute_save(state),
    do: Map.update(state, :pending_commands, [:save], &[:save | &1])

  @spec execute_quit(map()) :: map()
  defp execute_quit(state),
    do: Map.update(state, :pending_commands, [:quit], &[:quit | &1])

  @spec execute_force_quit(map()) :: map()
  defp execute_force_quit(state),
    do: Map.update(state, :pending_commands, [:force_quit], &[:force_quit | &1])

  @spec execute_quit_all(map()) :: map()
  defp execute_quit_all(state),
    do: Map.update(state, :pending_commands, [:quit_all], &[:quit_all | &1])

  @spec execute_force_quit_all(map()) :: map()
  defp execute_force_quit_all(state),
    do: Map.update(state, :pending_commands, [:force_quit_all], &[:force_quit_all | &1])

  @spec execute_move_left(map()) :: map()
  defp execute_move_left(state),
    do: Map.update(state, :pending_commands, [:move_left], &[:move_left | &1])

  @spec execute_move_right(map()) :: map()
  defp execute_move_right(state),
    do: Map.update(state, :pending_commands, [:move_right], &[:move_right | &1])

  @spec execute_move_up(map()) :: map()
  defp execute_move_up(state),
    do: Map.update(state, :pending_commands, [:move_up], &[:move_up | &1])

  @spec execute_move_down(map()) :: map()
  defp execute_move_down(state),
    do: Map.update(state, :pending_commands, [:move_down], &[:move_down | &1])

  @spec execute_delete_before(map()) :: map()
  defp execute_delete_before(state),
    do: Map.update(state, :pending_commands, [:delete_before], &[:delete_before | &1])

  @spec execute_delete_at(map()) :: map()
  defp execute_delete_at(state),
    do: Map.update(state, :pending_commands, [:delete_at], &[:delete_at | &1])

  @spec execute_insert_newline(map()) :: map()
  defp execute_insert_newline(state),
    do: Map.update(state, :pending_commands, [:insert_newline], &[:insert_newline | &1])

  @spec execute_undo(map()) :: map()
  defp execute_undo(state),
    do: Map.update(state, :pending_commands, [:undo], &[:undo | &1])

  @spec execute_redo(map()) :: map()
  defp execute_redo(state),
    do: Map.update(state, :pending_commands, [:redo], &[:redo | &1])

  @spec execute_generic(map(), atom()) :: map()
  defp execute_generic(state, cmd),
    do: Map.update(state, :pending_commands, [cmd], &[cmd | &1])

  # Maps a built-in command name to its execute function capture.
  @spec built_in_execute(atom()) :: function()
  defp built_in_execute(:save), do: &execute_save/1
  defp built_in_execute(:quit), do: &execute_quit/1
  defp built_in_execute(:force_quit), do: &execute_force_quit/1
  defp built_in_execute(:quit_all), do: &execute_quit_all/1
  defp built_in_execute(:force_quit_all), do: &execute_force_quit_all/1
  defp built_in_execute(:move_left), do: &execute_move_left/1
  defp built_in_execute(:move_right), do: &execute_move_right/1
  defp built_in_execute(:move_up), do: &execute_move_up/1
  defp built_in_execute(:move_down), do: &execute_move_down/1
  defp built_in_execute(:delete_before), do: &execute_delete_before/1
  defp built_in_execute(:delete_at), do: &execute_delete_at/1
  defp built_in_execute(:insert_newline), do: &execute_insert_newline/1
  defp built_in_execute(:undo), do: &execute_undo/1
  defp built_in_execute(:redo), do: &execute_redo/1
  defp built_in_execute(cmd), do: &execute_generic(&1, cmd)

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec build_initial_state() :: state()
  defp build_initial_state do
    Enum.reduce(@built_in_specs, %{}, fn {name, description}, acc ->
      cmd = %Command{
        name: name,
        description: description,
        execute: built_in_execute(name),
        scope: built_in_scope(name)
      }

      Map.put(acc, name, cmd)
    end)
  end

  # Scope descriptors for commands that toggle buffer-local options.
  # Returns nil for non-scopeable commands.
  @spec built_in_scope(atom()) :: Command.scope() | nil
  defp built_in_scope(:toggle_wrap), do: %{option: :wrap, toggle: true}

  defp built_in_scope(:cycle_line_numbers) do
    %{
      option: :line_numbers,
      toggle: fn
        :hybrid -> :absolute
        :absolute -> :relative
        :relative -> :none
        :none -> :hybrid
      end
    }
  end

  defp built_in_scope(_), do: nil
end
