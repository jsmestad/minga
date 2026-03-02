defmodule Minga.Editor.State.Registers do
  @moduledoc """
  Groups register-related fields from EditorState.

  Tracks the named register store and the currently selected register
  (set by `\"x` before an operator).
  """

  @typedoc """
  Register store. Keys are register names:
  - `\"\"` — unnamed (default)
  - `\"0\"` — last yank
  - `\"a\"`–`\"z\"` — named
  - `\"+\"` — system clipboard (virtual; read/write via Minga.Clipboard)
  - `\"_\"` — black hole (never stored)
  """
  @type registers :: %{String.t() => String.t()}

  @type t :: %__MODULE__{
          registers: registers(),
          active: String.t()
        }

  defstruct registers: %{},
            active: ""

  @doc "Puts `text` into the named register `name`."
  @spec put(t(), String.t(), String.t()) :: t()
  def put(%__MODULE__{} = reg, name, text) do
    %{reg | registers: Map.put(reg.registers, name, text)}
  end

  @doc "Gets the value of the named register `name`."
  @spec get(t(), String.t()) :: String.t() | nil
  def get(%__MODULE__{registers: regs}, name) do
    Map.get(regs, name)
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
