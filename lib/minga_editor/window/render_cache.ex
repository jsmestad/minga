defmodule MingaEditor.Window.RenderCache do
  @moduledoc """
  Editor-owned input-domain render metadata for a window.

  This deliberately small value may describe the viewport/cursor observation
  that produced an intent. Resident rows, content digests, durable identities,
  adapter caches, epochs, and frontend acknowledgement state belong to
  `MingaEditor.Renderer.State` and `MingaEditor.Renderer.WindowCache` instead.
  """

  @enforce_keys [:viewport_top, :viewport_left, :cursor_line, :cursor_col, :buffer_version]
  defstruct [:viewport_top, :viewport_left, :cursor_line, :cursor_col, :buffer_version]

  @type t :: %__MODULE__{
          viewport_top: non_neg_integer(),
          viewport_left: non_neg_integer(),
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer(),
          buffer_version: non_neg_integer()
        }

  @doc "Captures bounded editor input metadata for a render intent."
  @spec new(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def new(viewport_top, viewport_left, cursor_line, cursor_col, buffer_version) do
    %__MODULE__{
      viewport_top: viewport_top,
      viewport_left: viewport_left,
      cursor_line: cursor_line,
      cursor_col: cursor_col,
      buffer_version: buffer_version
    }
  end
end
