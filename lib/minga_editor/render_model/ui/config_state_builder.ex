defmodule MingaEditor.RenderModel.UI.ConfigStateBuilder do
  @moduledoc """
  Converts the wire-shaped native settings map into the semantic
  `Minga.RenderModel.UI.ConfigState` snapshot emitted in-frame (#2119).

  The snapshot is rarely-changing (it only moves when a settings option changes),
  so the editor caches it on `MingaEditor.State` and rebuilds it on option change
  via `MingaEditor.refresh_gui_config_state/1`. The render pipeline reads the
  cached snapshot each frame; the adapter encoder fingerprints it so an unchanged
  snapshot emits no bytes, and a keyframe re-emits it for free.

  This builder stays free of `MingaEditor.Frontend.Protocol.GUI`: the caller
  (which lives outside `lib/minga_editor/render_model/`) projects the config and
  keymap servers into the wire map and passes it here for the struct conversion.
  """

  alias Minga.RenderModel.UI.ConfigState

  @typedoc "Wire-shaped settings map (as produced by the config/keymap projection)."
  @type wire :: %{
          options: %{atom() => term()},
          theme_previews: [ConfigState.theme_preview()],
          keybindings: [ConfigState.keybinding()]
        }

  @doc """
  Converts a wire-shaped settings map into the semantic struct.

  Options become an ordered `{name_string, value}` list, preserving the source
  map's enumeration order so the encoded bytes stay identical to the legacy push.
  """
  @spec from_wire(wire()) :: ConfigState.t()
  def from_wire(%{options: options, theme_previews: previews, keybindings: bindings}) do
    %ConfigState{
      options: Enum.map(options, fn {name, value} -> {Atom.to_string(name), value} end),
      theme_previews: previews,
      keybindings: bindings
    }
  end
end
