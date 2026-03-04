defmodule Minga.Config do
  @moduledoc """
  DSL module for Minga user configuration.

  Used in `~/.config/minga/config.exs` (or `$XDG_CONFIG_HOME/minga/config.exs`)
  to declare editor options, custom keybindings, and commands. The config
  file is real Elixir code evaluated at startup.

  ## Example config file

      use Minga.Config

      # Options
      set :tab_width, 4
      set :line_numbers, :relative
      set :scroll_margin, 8

      # Custom keybindings
      bind :normal, "SPC g s", :git_status, "Git status"

      # Custom commands
      command :git_status, "Show git status" do
        {output, _} = System.cmd("git", ["status", "--short"])
        Minga.API.message(output)
      end

  ## Available options

  See `Minga.Config.Options` for the full list of supported options.
  """

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Config.Options
  alias Minga.Keymap.Store, as: KeymapStore

  require Logger

  @doc """
  Injects the config DSL into the calling module or script.

  Imports `Minga.Config` so that `set/2`, `bind/4`, and `command/3` are
  available without qualification.
  """
  defmacro __using__(_opts) do
    quote do
      import Minga.Config
    end
  end

  @doc """
  Sets an editor option.

  Validates the option name and value type, then stores the value in
  `Minga.Config.Options`. Raises `ArgumentError` if the option name is
  unknown or the value has the wrong type.

  ## Examples

      set :tab_width, 4
      set :line_numbers, :relative
  """
  @spec set(Options.option_name(), term()) :: :ok
  def set(name, value) when is_atom(name) do
    case Options.set(name, value) do
      {:ok, _} -> :ok
      {:error, msg} -> raise ArgumentError, msg
    end
  end

  @doc """
  Binds a key sequence to a command in the given mode.

  For normal mode, leader sequences (starting with `SPC`) are added to
  the leader trie. Single-key bindings override defaults.

  Invalid key sequences log a warning but don't crash.

  ## Examples

      bind :normal, "SPC g s", :git_status, "Git status"
      bind :normal, "SPC t t", :toggle_tree, "Toggle file tree"
  """
  @spec bind(atom(), String.t(), atom(), String.t()) :: :ok
  def bind(mode, key_str, command_name, description)
      when is_atom(mode) and is_binary(key_str) and is_atom(command_name) and
             is_binary(description) do
    case KeymapStore.bind(mode, key_str, command_name, description) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("bind failed: #{reason}")
    end

    :ok
  end

  @doc """
  Defines a custom command and registers it in the command registry.

  The block runs inside a supervised Task, so crashes don't take down
  the editor. Errors are shown in the status bar.

  ## Examples

      command :count_lines, "Count buffer lines" do
        count = Minga.API.line_count()
        Minga.API.message("Lines: \#{count}")
      end
  """
  defmacro command(name, description, do: block) do
    quote do
      Minga.Config.register_command(unquote(name), unquote(description), fn ->
        unquote(block)
      end)
    end
  end

  @doc """
  Registers a custom command (called by the `command/3` macro).

  Wraps the function in a Task under `Minga.Eval.TaskSupervisor` so that
  crashes are isolated from the editor process.
  """
  @spec register_command(atom(), String.t(), (-> term())) :: :ok
  def register_command(name, description, fun)
      when is_atom(name) and is_binary(description) and is_function(fun, 0) do
    execute_fn = fn state ->
      Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
        try do
          fun.()
        rescue
          e ->
            msg = "Command #{name} failed: #{Exception.message(e)}"
            Logger.warning(msg)

            try do
              Minga.API.message(msg)
            catch
              :exit, _ -> :ok
            end
        end
      end)

      state
    end

    CommandRegistry.register(CommandRegistry, name, description, execute_fn)
    :ok
  end

  @doc """
  Registers a lifecycle hook for an editor event.

  Hooks run asynchronously under a TaskSupervisor, so they won't block
  editing. Crashes are logged but don't affect the editor.

  ## Supported events

  * `:after_save` — receives `(buffer_pid, file_path)`
  * `:after_open` — receives `(buffer_pid, file_path)`
  * `:on_mode_change` — receives `(old_mode, new_mode)`

  ## Examples

      on :after_save, fn _buf, path ->
        System.cmd("mix", ["format", path])
      end
  """
  alias Minga.Config.Hooks

  @spec on(Hooks.event(), function()) :: :ok
  def on(event, fun) when is_atom(event) and is_function(fun) do
    case Hooks.register(event, fun) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Sets per-filetype option overrides.

  When a buffer of the given filetype is active, these values override
  the global defaults.

  ## Examples

      for_filetype :go, tab_width: 8
      for_filetype :python, tab_width: 4
      for_filetype :elixir, tab_width: 2, autopair: true
  """
  @spec for_filetype(atom(), keyword()) :: :ok
  def for_filetype(filetype, opts) when is_atom(filetype) and is_list(opts) do
    for {name, value} <- opts do
      case Options.set_for_filetype(filetype, name, value) do
        {:ok, _} -> :ok
        {:error, msg} -> raise ArgumentError, "for_filetype #{filetype}: #{msg}"
      end
    end

    :ok
  end
end
