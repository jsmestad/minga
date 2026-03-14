defmodule Minga.Editor.RenderPipeline.Emit do
  @moduledoc """
  Stage 7: Emit.

  Converts the composed `Frame` into protocol command binaries and
  sends them to the Zig renderer port. Also sends title and window
  background color when they change (side-channel writes).
  """

  alias Minga.Config.Options
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.Frame
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Title
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Converts the frame to protocol command binaries and sends them to
  the Zig port. Also sends title and window background color when they
  change (side-channel writes).
  """
  @spec emit(Frame.t(), state()) :: :ok
  def emit(frame, state) do
    commands = DisplayList.to_commands(frame)
    PortManager.send_commands(state.port_manager, commands)
    send_title(state)
    send_window_bg(state)
    :ok
  end

  @spec send_title(state()) :: :ok
  defp send_title(state) do
    format = Options.get(:title_format) |> to_string()
    title = Title.format(state, format)

    # Prepend [!] when any agent tab needs attention
    title =
      if state.tab_bar && TabBar.any_attention?(state.tab_bar) do
        "[!] " <> title
      else
        title
      end

    if title != Process.get(:last_title) do
      Process.put(:last_title, title)
      PortManager.send_commands([Protocol.encode_set_title(title)])
    end

    :ok
  end

  @spec send_window_bg(state()) :: :ok
  defp send_window_bg(state) do
    bg = state.theme.editor.bg

    if bg != Process.get(:last_window_bg) do
      Process.put(:last_window_bg, bg)
      PortManager.send_commands([Protocol.encode_set_window_bg(bg)])
    end

    :ok
  end
end
