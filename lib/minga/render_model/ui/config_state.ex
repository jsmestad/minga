defmodule Minga.RenderModel.UI.ConfigState do
  @moduledoc false

  # Native settings panel state. The builder projects the editor's config and
  # keymap into plain wire-ready data so the Layer 1 encoder stays free of any
  # MingaEditor dependency:
  #
  #   * `options` is an ordered list of `{name_string, value}` pairs, where value
  #     is a boolean, integer, float, atom, or string. The encoder tags each by
  #     type on the wire.
  #   * `theme_previews` is a list of swatch maps (name, atom, editor_bg,
  #     editor_fg, accent).
  #   * `keybindings` is a list of read-only binding maps (mode, key, command,
  #     description).
  @type value :: boolean() | integer() | float() | atom() | String.t()

  @type option :: {name :: String.t(), value :: value()}

  @type theme_preview :: %{
          name: String.t(),
          atom: String.t(),
          editor_bg: non_neg_integer(),
          editor_fg: non_neg_integer(),
          accent: non_neg_integer()
        }

  @type keybinding :: %{
          mode: String.t(),
          key: String.t(),
          command: String.t(),
          description: String.t()
        }

  @type t :: %__MODULE__{
          options: [option()],
          theme_previews: [theme_preview()],
          keybindings: [keybinding()]
        }

  @enforce_keys [:options]
  defstruct options: [], theme_previews: [], keybindings: []
end
