defmodule MingaEditor.State.Interaction do
  @moduledoc """
  Per-editor input configuration and transient interaction history.

  The value owns editing-model selection, isolated keymap/options services,
  and keystroke history used by input diagnostics.
  """

  alias MingaEditor.KeystrokeHistory

  @type editing_model :: :vim | :cua
  @type t :: %__MODULE__{
          editing_model: editing_model(),
          keymap_server: Minga.Keymap.server(),
          options_server: Minga.Config.Options.server(),
          keystroke_history: KeystrokeHistory.t()
        }

  defstruct editing_model: :vim,
            keymap_server: Minga.Keymap.Active,
            options_server: Minga.Config.Options,
            keystroke_history: KeystrokeHistory.new()

  @doc "Creates interaction state from startup configuration."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      editing_model: Keyword.get(opts, :editing_model, :vim),
      keymap_server: Keyword.get(opts, :keymap_server, Minga.Keymap.Active),
      options_server: Keyword.get(opts, :options_server, Minga.Config.Options)
    }
  end

  @doc "Commits keystroke history produced by the input recorder."
  @spec accept_keystroke_history(t(), KeystrokeHistory.t()) :: t()
  def accept_keystroke_history(%__MODULE__{} = interaction, %KeystrokeHistory{} = history),
    do: %{interaction | keystroke_history: history}
end
