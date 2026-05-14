defmodule MingaEditor.Shell.Chrome do
  @moduledoc """
  Behaviour: how a shell builds chrome (tab bar, modeline, file tree,
  overlays) and renders complete frames.

  Carved out of `MingaEditor.Shell` so the rendering responsibility is
  declared as a focused contract independent of input routing or buffer
  lifecycle.
  """

  @doc """
  Returns a chrome struct with draw lists for each UI region. The shell
  decides which chrome elements exist and how they render.
  """
  @callback build_chrome(
              editor_state :: term(),
              layout :: MingaEditor.Layout.t(),
              scrolls :: map(),
              cursor_info :: term()
            ) :: MingaEditor.RenderPipeline.Chrome.t()

  @doc "Returns shell-specific data that affects chrome dirty tracking."
  @callback chrome_fingerprint(editor_state :: term()) :: term()

  @doc "Returns true when the shell's current state can safely render through the asynchronous RenderPipeline path."
  @callback async_render?(editor_state :: term()) :: boolean()

  @doc """
  Runs the full render pipeline (content, chrome, compose, emit) and
  sends commands to the frontend. Returns updated state with cached
  render data.
  """
  @callback render(editor_state :: term()) :: term()
end
