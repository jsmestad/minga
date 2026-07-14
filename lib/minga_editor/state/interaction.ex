defmodule MingaEditor.State.Interaction do
  @moduledoc """
  Per-editor input configuration and transient interaction history.

  The value owns editing-model selection, isolated keymap/options services,
  layered focus routing, and keystroke history used by input diagnostics.
  """

  alias MingaEditor.KeystrokeHistory

  @type editing_model :: :vim | :cua
  @type t :: %__MODULE__{
          editing_model: editing_model(),
          keymap_server: Minga.Keymap.server(),
          options_server: Minga.Config.Options.server(),
          focus_stack: [module()],
          keystroke_history: KeystrokeHistory.t()
        }

  defstruct editing_model: :vim,
            keymap_server: Minga.Keymap.Active,
            options_server: Minga.Config.Options,
            focus_stack: [],
            keystroke_history: KeystrokeHistory.new()

  @doc "Creates interaction state from startup configuration."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      editing_model: Keyword.get(opts, :editing_model, :vim),
      keymap_server: Keyword.get(opts, :keymap_server, Minga.Keymap.Active),
      options_server: Keyword.get(opts, :options_server, Minga.Config.Options),
      focus_stack: Keyword.get(opts, :focus_stack, [])
    }
  end

  @doc "Pushes an input handler unless it already owns focus."
  @spec focus(t(), module()) :: t()
  def focus(%__MODULE__{focus_stack: [handler | _]} = interaction, handler), do: interaction

  def focus(%__MODULE__{} = interaction, handler) when is_atom(handler),
    do: %{interaction | focus_stack: [handler | interaction.focus_stack]}

  @doc "Removes an input handler from the focus route."
  @spec blur(t(), module()) :: t()
  def blur(%__MODULE__{} = interaction, handler) when is_atom(handler),
    do: %{interaction | focus_stack: List.delete(interaction.focus_stack, handler)}

  @doc "Commits keystroke history produced by the input recorder."
  @spec accept_keystroke_history(t(), KeystrokeHistory.t()) :: t()
  def accept_keystroke_history(%__MODULE__{} = interaction, %KeystrokeHistory{} = history),
    do: %{interaction | keystroke_history: history}
end
