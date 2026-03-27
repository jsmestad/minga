defmodule Minga.Command do
  @moduledoc """
  A named editor command.

  Commands are the bridge between key sequences (via the keymap trie)
  and editor state mutations. Each command has a name (for registry
  lookup), a human-readable description (for which-key display), and
  an execute function that maps editor state → new editor state.

  ## Scopeable commands

  Commands that toggle buffer-local options can declare a `scope`
  descriptor. When invoked from a keybinding, scopeable commands
  apply to the current buffer (fast path). When invoked from the
  command palette, the palette presents a scope picker ("This Buffer"
  / "All Buffers") so the user can choose where the change applies.

  The scope descriptor is a map with:

  * `:option` — the option name atom (e.g. `:wrap`)
  * `:toggle` — `true` for boolean toggle, or a function
    `(current_value -> new_value)` for non-boolean cycling

  ## Buffer requirement

  Commands that only make sense with an active buffer set
  `requires_buffer: true`. The dispatch layer skips these commands
  (returning state unchanged) when no buffer is active.

  ## Example

      %Minga.Command{
        name: :save,
        description: "Save the current file",
        execute: fn state -> Minga.Editor.Commands.BufferManagement.execute(state, :save) end,
        requires_buffer: true
      }

      # Scopeable toggle:
      %Minga.Command{
        name: :toggle_wrap,
        description: "Toggle word wrap",
        execute: fn state -> Minga.Editor.Commands.BufferManagement.execute(state, :toggle_wrap) end,
        requires_buffer: true,
        scope: %{option: :wrap, toggle: true}
      }
  """

  @enforce_keys [:name, :description, :execute]
  defstruct [:name, :description, :execute, :scope, requires_buffer: false]

  @typedoc """
  Scope descriptor for commands that toggle buffer-local options.

  * `:option` — the option name atom
  * `:toggle` — `true` for boolean negation, or a `(term -> term)` function
  """
  @type scope :: %{option: atom(), toggle: true | (term() -> term())}

  @typedoc """
  An editor command struct.

  * `name`            — atom identifier used for registry lookup and keymap binding
  * `description`     — human-readable label shown in which-key popups
  * `execute`         — function applied to the editor state, returns new state
  * `requires_buffer` — when true, command is skipped if no buffer is active
  * `scope`           — optional scope descriptor for buffer-local option toggles
  """
  @type t :: %__MODULE__{
          name: atom(),
          description: String.t(),
          execute: function(),
          requires_buffer: boolean(),
          scope: scope() | nil
        }

  # ── Registry lookup ──────────────────────────────────────────────────

  @doc "Looks up a command by name. Returns `{:ok, command}` or `:error`."
  @spec lookup(atom()) :: {:ok, t()} | :error
  def lookup(name) when is_atom(name) do
    Minga.Command.Registry.lookup(Minga.Command.Registry, name)
  end

  @doc "Returns all registered commands as a list."
  @spec all_commands() :: [t()]
  def all_commands do
    Minga.Command.Registry.all(Minga.Command.Registry)
  end

  @doc "Registers a command with name, description, and execute function."
  @spec register(atom(), String.t(), (term() -> term())) :: :ok
  def register(name, description, execute) do
    Minga.Command.Registry.register(Minga.Command.Registry, name, description, execute)
  end

  @doc "Resets the registry to built-in commands (discards user/extension commands)."
  @spec reset_registry() :: :ok
  defdelegate reset_registry, to: Minga.Command.Registry, as: :reset

  # ── Parsing ────────────────────────────────────────────────────────────

  @doc "Parses a command-line string into a structured command invocation."
  @spec parse(String.t()) :: Minga.Command.Parser.parsed()
  defdelegate parse(input), to: Minga.Command.Parser

  # ── Command properties ─────────────────────────────────────────────────

  @doc "Returns true if this command is scopeable (toggles a buffer-local option)."
  @spec scopeable?(t()) :: boolean()
  def scopeable?(%__MODULE__{scope: nil}), do: false
  def scopeable?(%__MODULE__{scope: %{option: _, toggle: _}}), do: true

  @doc """
  Computes the new value for a scopeable command given the current value.

  For `toggle: true`, negates the boolean. For a function, calls it.
  """
  @spec compute_new_value(t(), term()) :: term()
  def compute_new_value(%__MODULE__{scope: %{toggle: true}}, current), do: !current

  def compute_new_value(%__MODULE__{scope: %{toggle: f}}, current) when is_function(f, 1),
    do: f.(current)
end
