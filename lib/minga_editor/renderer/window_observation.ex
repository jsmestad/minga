defmodule MingaEditor.Renderer.WindowObservation do
  @moduledoc "Bounded renderer-to-editor viewport and buffer-version observation."

  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Viewport

  @enforce_keys [:buffer, :buffer_version, :viewport]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          buffer: pid(),
          buffer_version: non_neg_integer(),
          viewport: Viewport.t()
        }

  @doc "Captures the editor-owned fields observed while rendering one buffer window."
  @spec from_window(RenderWindow.t()) :: t() | nil
  def from_window(%RenderWindow{
        content: {:buffer, buffer},
        render_cache: cache,
        viewport: %Viewport{} = viewport
      })
      when is_pid(buffer) do
    %__MODULE__{
      buffer: buffer,
      buffer_version: max(cache.last_buf_version, 0),
      viewport: viewport
    }
  end

  def from_window(%RenderWindow{}), do: nil
end
