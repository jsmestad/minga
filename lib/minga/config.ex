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

  alias Minga.Command
  alias Minga.Config.Advice
  alias Minga.Config.Completion
  alias Minga.Config.Loader
  alias Minga.Config.Options
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Keymap
  alias Minga.UI.Popup.Registry, as: PopupRegistry
  alias Minga.UI.Popup.Rule, as: PopupRule

  # ── Read options ───────────────────────────────────────────────────

  @doc """
  Reads a config option value.

  ## Examples

      Config.get(:tab_width)    #=> 2
      Config.get(:theme)        #=> :doom_one
  """
  @spec get(Options.option_name()) :: term()
  defdelegate get(name), to: Options

  @doc """
  Reads a config option, merging per-filetype overrides when present.

  Returns the filetype-specific value if one was set via `for_filetype/2`,
  otherwise falls back to the global value.
  """
  @spec get_for_filetype(Options.option_name(), atom() | nil) :: term()
  defdelegate get_for_filetype(name, filetype), to: Options

  @doc """
  Reads an extension option value.

  ## Examples

      Config.get_extension_option(:minga_org, :conceal)  #=> true
  """
  @spec get_extension_option(atom(), atom()) :: term()
  defdelegate get_extension_option(ext_name, opt_name), to: Options

  @doc """
  Reads an extension option, merging per-filetype overrides when present.
  """
  @spec get_extension_option_for_filetype(atom(), atom(), atom() | nil) :: term()
  defdelegate get_extension_option_for_filetype(ext_name, opt_name, filetype), to: Options

  # ── Write options (non-raising) ────────────────────────────────────

  @doc """
  Sets an option, returning `{:ok, value}` or `{:error, message}`.

  Unlike `set/2` (used in config.exs DSL which raises on error), this
  returns the result tuple for callers that handle errors themselves.
  """
  @spec set_option(Options.option_name(), term()) :: {:ok, term()} | {:error, String.t()}
  defdelegate set_option(name, value), to: Options, as: :set

  @doc """
  Sets an extension option, returning `{:ok, value}` or `{:error, message}`.
  """
  @spec set_extension_option!(atom(), atom(), term()) :: {:ok, term()} | {:error, String.t()}
  defdelegate set_extension_option!(ext_name, opt_name, value),
    to: Options,
    as: :set_extension_option

  @doc """
  Sets an extension option override for a specific filetype.
  """
  @spec set_extension_option_for_filetype(atom(), atom(), atom(), term()) ::
          {:ok, term()} | {:error, String.t()}
  defdelegate set_extension_option_for_filetype(ext_name, filetype, opt_name, value), to: Options

  # ── Extension schema ───────────────────────────────────────────────

  @doc """
  Registers an extension's option schema and applies user config.

  Called by the extension supervisor when loading an extension.
  """
  @spec register_extension_schema(atom(), [Minga.Extension.option_spec()], keyword()) ::
          :ok | {:error, [String.t()]}
  defdelegate register_extension_schema(ext_name, schema, user_config), to: Options

  @doc """
  Returns the registered option schema for an extension, or nil.
  """
  @spec extension_schema(atom()) :: [Minga.Extension.option_spec()] | nil
  defdelegate extension_schema(ext_name), to: Options

  # ── Command advice ─────────────────────────────────────────────────

  @doc """
  Wraps a command function with any registered before/after/around/override advice.

  Returns a `(state -> state)` function that applies the full advice chain.
  """
  @spec wrap_with_advice(atom(), (term() -> term())) :: (term() -> term())
  defdelegate wrap_with_advice(command_name, execute), to: Advice, as: :wrap

  # ── Config discovery ───────────────────────────────────────────────

  @doc """
  Returns the path to the user's config file (`~/.config/minga/config.exs`).
  """
  @spec config_path() :: String.t()
  defdelegate config_path(), to: Loader

  @doc "Re-evaluates the user's config file. Returns `:ok` or `{:error, reason}`."
  @spec reload() :: :ok | {:error, term()}
  defdelegate reload(), to: Loader

  @doc "Returns the error from the last config load, or nil if it loaded cleanly."
  @spec load_error() :: term() | nil
  defdelegate load_error(), to: Loader

  # ── Completion ─────────────────────────────────────────────────────

  @doc "Completion items for `:set` option names."
  @spec option_name_completions() :: [map()]
  defdelegate option_name_completions(), to: Completion, as: :option_name_items

  @doc "Completion items for values of a specific option."
  @spec option_value_completions(Options.option_name()) :: [map()]
  defdelegate option_value_completions(name), to: Completion, as: :option_value_items

  @doc "Completion items for filetype names."
  @spec filetype_completions() :: [map()]
  defdelegate filetype_completions(), to: Completion, as: :filetype_items

  # ── Validation ──────────────────────────────────────────────────────

  @doc "Returns the set of all recognized option names."
  @spec valid_option_names() :: MapSet.t(atom())
  defdelegate valid_option_names(), to: Options, as: :valid_names

  @doc "Validates an option name/value pair without storing it."
  @spec validate_option(Options.option_name(), term()) :: {:ok, term()} | {:error, String.t()}
  defdelegate validate_option(name, value), to: Options, as: :validate_option

  # ── Type re-exports ────────────────────────────────────────────────

  @type option_name :: Options.option_name()
  @type type_descriptor :: Options.type_descriptor()

  # ── Config DSL ─────────────────────────────────────────────────────

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
  Sets an extension option at runtime.

  Use this from commands, keybindings, or extension code to change an
  extension option after load. Not usable in `config.exs` (the schema
  isn't registered yet at config eval time; use the extension declaration
  syntax instead).

  ## Examples

      set_extension_option :minga_org, :conceal, false
      set_extension_option :minga_org, :heading_bullets, ["•", "◦"]
  """
  @spec set_extension_option(atom(), atom(), term()) :: :ok
  def set_extension_option(extension, name, value)
      when is_atom(extension) and is_atom(name) do
    case Options.set_extension_option(extension, name, value) do
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
        Keymap.bind(mode, key_str, command_name, description, filetype: filetype)
      else
        Keymap.bind(mode, key_str, command_name, description)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> Minga.Log.warning(:config, "bind failed: #{reason}")
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
    case Keymap.bind(mode, key_str, command_name, description, opts) do
      :ok -> :ok
      {:error, reason} -> Minga.Log.warning(:config, "bind failed: #{reason}")
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
          Minga.Editor.State.set_status(state, "Skipping format: has errors")
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
            Minga.Log.warning(:config, msg)

            try do
              Minga.API.message(msg)
            catch
              :exit, _ -> :ok
            end
        end
      end)

      state
    end

    Command.register(name, description, execute_fn)
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
  Declares a popup rule for a buffer name pattern.

  When a buffer whose name matches `pattern` is opened, it will be
  displayed according to the rule instead of replacing the current buffer.
  Later registrations with the same pattern override earlier ones, so user
  config overrides built-in defaults.

  ## Split mode (default)

      popup "*Warnings*", side: :bottom, size: {:percent, 30}, focus: false
      popup "*compilation*", side: :bottom, size: {:percent, 25}, focus: false
      popup ~r/\\*grep/, side: :right, size: {:percent, 40}, focus: true

  ## Float mode

      popup ~r/\\*Help/, display: :float, width: {:percent, 60},
        height: {:percent, 70}, border: :rounded, focus: true, auto_close: true

  ## Options

  See `Minga.UI.Popup.Rule` for the full list of supported options.
  """
  @spec popup(Regex.t() | String.t(), keyword()) :: :ok
  def popup(pattern, opts \\ []) when is_binary(pattern) or is_struct(pattern, Regex) do
    rule = PopupRule.new(pattern, opts)
    PopupRegistry.unregister(pattern)
    PopupRegistry.register(rule)
  end

  @doc """
  Declares an extension to load.

  Exactly one source must be provided: `path:`, `git:`, or `hex:`.
  Extra keyword options (beyond the source and its options) are passed
  to the extension's `init/1` callback as config.

  ## Path source (local development)

      extension :my_tool, path: "~/code/minga_my_tool"
      extension :greeter, path: "~/code/greeter", greeting: "howdy"

  ## Git source (bleeding-edge or private)

      extension :snippets, git: "https://github.com/user/minga_snippets"
      extension :snippets, git: "https://github.com/user/minga_snippets", branch: "main"
      extension :snippets, git: "git@github.com:user/minga_snippets.git", ref: "v1.0.0"

  ## Hex source (stable, published)

      extension :snippets, hex: "minga_snippets", version: "~> 0.3"
      extension :snippets, hex: "minga_snippets"
  """
  @spec extension(atom(), keyword()) :: :ok
  def extension(name, opts) when is_atom(name) and is_list(opts) do
    has_path = Keyword.has_key?(opts, :path)
    has_git = Keyword.has_key?(opts, :git)
    has_hex = Keyword.has_key?(opts, :hex)

    source_count = Enum.count([has_path, has_git, has_hex], & &1)

    if source_count == 0 do
      raise ArgumentError,
            "extension #{name}: one of :path, :git, or :hex is required"
    end

    if source_count > 1 do
      raise ArgumentError,
            "extension #{name}: only one of :path, :git, or :hex can be specified"
    end

    register_extension_source(name, opts, {has_path, has_git, has_hex})
  end

  @spec register_extension_source(atom(), keyword(), {boolean(), boolean(), boolean()}) :: :ok
  defp register_extension_source(name, opts, {true, false, false}) do
    {path, config} = Keyword.pop(opts, :path)
    expanded = Path.expand(path)

    unless File.dir?(expanded) do
      Minga.Log.warning(:config, "extension #{name}: path does not exist: #{expanded}")
    end

    ExtRegistry.register(name, expanded, config)
  end

  defp register_extension_source(name, opts, {false, true, false}) do
    {url, rest} = Keyword.pop(opts, :git)

    unless is_binary(url) and url != "" do
      raise ArgumentError, "extension #{name}: :git value must be a non-empty URL string"
    end

    ExtRegistry.register_git(name, url, rest)
  end

  defp register_extension_source(name, opts, {false, false, true}) do
    {package, rest} = Keyword.pop(opts, :hex)

    unless is_binary(package) and package != "" do
      raise ArgumentError, "extension #{name}: :hex value must be a non-empty package name"
    end

    ExtRegistry.register_hex(name, package, rest)
  end
end
