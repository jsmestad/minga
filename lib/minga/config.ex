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

      # Command advice (skip formatting if buffer has errors)
      advise :around, :format_buffer, fn execute, state ->
        if error_free?(state), do: execute.(state), else: state
      end

  ## Available options

  See `Minga.Config.Options` for the full list of supported options.
  """

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Config.Advice
  alias Minga.Config.Options
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Keymap.Active, as: KeymapActive

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

  Supports all vim modes: `:normal`, `:insert`, `:visual`,
  `:operator_pending`, `:command`. For scope-specific bindings, pass a
  `{scope, vim_state}` tuple (e.g., `{:agent, :normal}`).

  For normal mode, leader sequences (starting with `SPC`) are added to
  the leader trie. Single-key bindings override defaults.

  Invalid key sequences log a warning but don't crash.

  ## Examples

      bind :normal, "SPC g s", :git_status, "Git status"
      bind :insert, "C-j", :next_line, "Next line"
      bind :visual, "SPC x", :custom_delete, "Custom delete"
      bind {:agent, :normal}, "y", :my_agent_copy, "Custom copy"
  """
  @spec bind(atom() | {atom(), atom()}, String.t(), atom(), String.t()) :: :ok
  def bind(mode, key_str, command_name, description)
      when is_binary(key_str) and is_atom(command_name) and is_binary(description) do
    # If we're inside a `keymap :filetype do ... end` block, automatically
    # scope the binding to that filetype.
    filetype = Process.get(:minga_config_filetype)

    result =
      if filetype do
        KeymapActive.bind(mode, key_str, command_name, description, filetype: filetype)
      else
        KeymapActive.bind(mode, key_str, command_name, description)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> Logger.warning("bind failed: #{reason}")
    end

    :ok
  end

  @doc """
  Binds a key sequence to a command with options.

  Supports the `filetype:` option for filetype-scoped bindings under
  the `SPC m` leader prefix.

  ## Examples

      bind :normal, "SPC m t", :mix_test, "Run tests", filetype: :elixir
      bind :normal, "SPC m p", :markdown_preview, "Preview", filetype: :markdown
  """
  @spec bind(atom(), String.t(), atom(), String.t(), keyword()) :: :ok
  def bind(mode, key_str, command_name, description, opts)
      when is_atom(mode) and is_binary(key_str) and is_atom(command_name) and
             is_binary(description) and is_list(opts) do
    case KeymapActive.bind(mode, key_str, command_name, description, opts) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("bind failed: #{reason}")
    end

    :ok
  end

  @doc """
  Wraps an existing command with advice.

  Four phases are supported, matching Emacs's advice system:

  * `:before` — `fn state -> state end` — transforms state before the command
  * `:after` — `fn state -> state end` — transforms state after the command
  * `:around` — `fn execute, state -> state end` — receives the original command function; full control over whether and how it runs
  * `:override` — `fn state -> state end` — completely replaces the command

  Multiple advice functions for the same phase and command run in
  registration order. For `:around`, they nest outward (first registered
  is outermost). Crashes in advice are logged but don't affect the editor.

  ## Examples

      # Run before save
      advise :before, :save, fn state ->
        state
      end

      # Conditionally skip formatting
      advise :around, :format_buffer, fn execute, state ->
        if state.diagnostics_count == 0 do
          execute.(state)
        else
          %{state | status_msg: "Skipping format: has errors"}
        end
      end

      # Replace a command entirely
      advise :override, :save, fn state ->
        my_custom_save(state)
      end
  """
  @spec advise(Advice.phase(), atom(), function()) :: :ok
  def advise(phase, command_name, fun)
      when is_atom(phase) and is_atom(command_name) and is_function(fun) do
    case Advice.register(phase, command_name, fun) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "advise failed: #{reason}"
    end
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

  @doc """
  Declares filetype-scoped keybindings.

  Bindings declared inside the block are scoped to the given filetype
  and appear under the `SPC m` leader prefix. This is the primary way
  to define language-specific key bindings.

  ## Examples

      keymap :elixir do
        bind :normal, "SPC m t", :mix_test, "Run tests"
        bind :normal, "SPC m f", :mix_format, "Format with mix"
      end

      keymap :markdown do
        bind :normal, "SPC m p", :markdown_preview, "Preview"
      end
  """
  defmacro keymap(filetype, do: block) do
    quote do
      Minga.Config.__keymap_scope__(unquote(filetype), fn ->
        unquote(block)
      end)
    end
  end

  @doc false
  @spec __keymap_scope__(atom(), (-> term())) :: :ok
  def __keymap_scope__(filetype, fun) when is_atom(filetype) and is_function(fun, 0) do
    # Store the filetype in process dictionary so bind/5 can pick it up
    previous = Process.get(:minga_config_filetype)
    Process.put(:minga_config_filetype, filetype)

    try do
      fun.()
    after
      if previous do
        Process.put(:minga_config_filetype, previous)
      else
        Process.delete(:minga_config_filetype)
      end
    end

    :ok
  end

  @doc """
  Declares an extension to load from a local path.

  The extension module at `path` must implement the `Minga.Extension`
  behaviour. Extra keyword options (beyond `:path`) are passed to the
  extension's `init/1` callback as config.

  ## Examples

      extension :my_tool, path: "~/code/minga_my_tool"
      extension :greeter, path: "~/code/greeter", greeting: "howdy"
  """
  @spec extension(atom(), keyword()) :: :ok
  def extension(name, opts) when is_atom(name) and is_list(opts) do
    {path, config} = Keyword.pop(opts, :path)

    if is_nil(path) do
      raise ArgumentError, "extension #{name}: :path option is required"
    end

    expanded = Path.expand(path)

    unless File.dir?(expanded) do
      Logger.warning("extension #{name}: path does not exist: #{expanded}")
    end

    ExtRegistry.register(name, expanded, config)
  end
end
