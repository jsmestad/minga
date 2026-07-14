defmodule MingaEditor.State.Appearance do
  @moduledoc """
  Per-editor appearance configuration shared by render frontends.

  Theme selection, native font override, and the cached semantic GUI settings
  snapshot move together while parser highlight recoloring remains a root-wide
  appearance/parser transition.
  """

  alias Minga.RenderModel.UI.ConfigState
  alias MingaEditor.UI.Theme

  @type t :: %__MODULE__{
          theme: Theme.t(),
          font_size_override: pos_integer() | nil,
          gui_config_state: ConfigState.t() | nil
        }

  defstruct theme: MingaEditor.UI.Theme.Fallback.theme(),
            font_size_override: nil,
            gui_config_state: nil

  @doc "Selects the active editor theme."
  @spec select_theme(t(), Theme.t()) :: t()
  def select_theme(%__MODULE__{} = appearance, %Theme{} = theme),
    do: %{appearance | theme: theme}

  @doc "Applies or clears the per-editor native font-size override."
  @spec override_font_size(t(), pos_integer() | nil) :: t()
  def override_font_size(%__MODULE__{} = appearance, size)
      when is_nil(size) or (is_integer(size) and size > 0),
      do: %{appearance | font_size_override: size}

  @doc "Caches the semantic native settings snapshot emitted in-frame."
  @spec cache_gui_config(t(), ConfigState.t() | nil) :: t()
  def cache_gui_config(%__MODULE__{} = appearance, snapshot),
    do: %{appearance | gui_config_state: snapshot}
end
