defmodule MingaEditor.State.Registers do
  @moduledoc """
  Groups register-related fields from EditorState.

  Tracks the named register store and the currently selected register
  (set by `\"x` before an operator).

  Each register entry is a `{text, type}` tuple where type is `:charwise`
  or `:linewise`. Linewise entries (from `yy`, `dd`, visual-line yank)
  paste as new lines; charwise entries paste inline at the cursor.
  """

  @typedoc "Whether register content should paste as whole lines or inline text."
  @type reg_type :: :charwise | :linewise

  @typedoc "A register entry: text content paired with its paste type."
  @type entry :: {String.t(), reg_type()}

  @typedoc """
  Register store. Keys are register names:
  - `\"\"` — unnamed (default)
  - `\"0\"` — last yank
  - `\"a\"`–`\"z\"` — named
  - `\"+\"` — system clipboard (virtual; read/write via Minga.Clipboard)
  - `\"_\"` — black hole (never stored)
  """
  @type registers :: %{String.t() => entry()}

  @type t :: %__MODULE__{
          registers: registers(),
          active: String.t()
        }

  defstruct registers: %{},
            active: ""

  @doc "Puts `text` into the named register `name` with the given type."
  @spec put(t(), String.t(), String.t(), reg_type()) :: t()
  def put(%__MODULE__{} = reg, name, text, type \\ :charwise) do
    %{reg | registers: Map.put(reg.registers, name, {text, type})}
  end

  @doc "Gets the entry for the named register `name`. Returns `{text, type}` or `nil`."
  @spec get(t(), String.t()) :: entry() | nil
  def get(%__MODULE__{registers: regs}, name) do
    case Map.get(regs, name) do
      # Migrate bare strings from old format (e.g., tests, deserialized state)
      text when is_binary(text) -> {text, :charwise}
      other -> other
    end
  end

  @doc "Resets the active register selection to unnamed."
  @spec reset_active(t()) :: t()
  def reset_active(%__MODULE__{} = reg) do
    %{reg | active: ""}
  end

  @doc "Sets the active register to `name`."
  @spec set_active(t(), String.t()) :: t()
  def set_active(%__MODULE__{} = reg, name) do
    %{reg | active: name}
  end
end
