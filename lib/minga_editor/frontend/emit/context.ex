defmodule MingaEditor.Frontend.Emit.Context do
  @moduledoc """
  Focused data contract for the emit pipeline.

  Contains exactly what the emit stage needs from the editor state,
  decoupling it from `MingaEditor.State.t()`. The Editor builds this context
  in the render pipeline's Emit stage before calling `Emit.emit/3`.
  """

  alias MingaEditor.Agent.UIState
  alias Minga.Editing.Completion
  alias MingaEditor.Layout
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Theme

  @type t :: %__MODULE__{
          port_manager: pid(),
          capabilities: Capabilities.t(),
          theme: Theme.t(),
          font_registry: FontRegistry.t(),
          windows: Windows.t(),
          layout: Layout.t(),
          shell: module(),
          shell_state: term(),
          tab_bar: TabBar.t() | nil,
          buffers: Buffers.t(),
          viewport: Viewport.t(),
          file_tree: FileTree.t(),
          highlight: Highlighting.t(),
          agent_ui: UIState.t(),
          completion: Completion.t() | nil,
          editing: VimState.t(),
          message_store: MingaEditor.UI.Panel.MessageStore.t(),
          title: String.t(),
          status_bar_data: term()
        }

  @enforce_keys [:port_manager, :capabilities, :theme, :font_registry, :windows, :layout, :shell]
  defstruct port_manager: nil,
            capabilities: nil,
            theme: nil,
            font_registry: nil,
            windows: nil,
            layout: nil,
            shell: nil,
            shell_state: nil,
            tab_bar: nil,
            buffers: nil,
            viewport: nil,
            file_tree: nil,
            highlight: nil,
            agent_ui: nil,
            completion: nil,
            editing: nil,
            message_store: nil,
            title: "Minga",
            status_bar_data: nil

  @doc "Builds an emit context from the full editor state."
  @spec from_editor_state(map()) :: t()
  def from_editor_state(state) do
    title = compute_title(state)

    %__MODULE__{
      port_manager: state.port_manager,
      capabilities: state.capabilities,
      theme: state.theme,
      font_registry: state.font_registry,
      windows: state.workspace.windows,
      layout: MingaEditor.Layout.get(state),
      shell: state.shell,
      shell_state: state.shell_state,
      tab_bar: Map.get(state.shell_state, :tab_bar),
      buffers: state.workspace.buffers,
      viewport: state.workspace.viewport,
      file_tree: state.workspace.file_tree,
      highlight: state.workspace.highlight,
      agent_ui: state.workspace.agent_ui,
      completion: state.workspace.completion,
      editing: state.workspace.editing,
      message_store: state.message_store,
      title: title,
      status_bar_data: MingaEditor.StatusBar.Data.from_state(state)
    }
  end

  @spec compute_title(map()) :: String.t()
  defp compute_title(
         %{shell: MingaEditor.Shell.Board, shell_state: %{zoomed_into: card_id}} = state
       )
       when card_id != nil do
    card = MingaEditor.Shell.Board.State.zoomed(state.shell_state)
    card_name = if card, do: card.task, else: "Board"
    "#{card_name} \u2014 Minga"
  end

  defp compute_title(%{shell: MingaEditor.Shell.Board}) do
    "The Board \u2014 Minga"
  end

  defp compute_title(state) do
    if MingaEditor.Frontend.gui?(state.capabilities) do
      MingaEditor.Title.format_gui(state)
    else
      format = Minga.Config.get(:title_format) |> to_string()
      title = MingaEditor.Title.format(state, format)
      tb = state.shell_state && Map.get(state.shell_state, :tab_bar)

      if tb && TabBar.any_attention?(tb) do
        "[!] " <> title
      else
        title
      end
    end
  end
end
