defmodule MingaEditor.Frontend.Emit.Context do
  @moduledoc """
  Focused data contract for the emit pipeline.

  Contains exactly what the emit stage needs from the render pipeline input,
  decoupling it from `State.t()`. The pipeline builds this context
  in the Emit stage before calling `Emit.emit/4`.
  """

  alias MingaEditor.Agent.UIState
  alias Minga.Editing.Completion
  alias MingaEditor.Layout
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Search
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Traditional.GitToast
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.NotificationCenter
  alias MingaEditor.UI.Theme
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.State

  @type t :: %__MODULE__{
          port_manager: GenServer.server() | nil,
          capabilities: Capabilities.t(),
          theme: Theme.t() | nil,
          font_registry: FontRegistry.t(),
          windows: Windows.t(),
          layout: Layout.t(),
          shell_id: atom(),
          shell: module(),
          shell_state: term(),
          tab_bar: TabBar.t() | nil,
          buffers: Buffers.t(),
          viewport: Viewport.t(),
          file_tree: FileTree.t(),
          highlight: Highlighting.t(),
          agent_ui: UIState.t(),
          launchpad: MingaEditor.State.Launchpad.t() | nil,
          completion: Completion.t() | nil,
          keymap_scope: Minga.Keymap.Scope.scope_name(),
          editing: VimState.t(),
          message_store: MingaEditor.UI.Panel.MessageStore.t(),
          notifications: NotificationCenter.t(),
          sidebar_registry: MingaEditor.Extension.Sidebar.table(),
          title: String.t(),
          status_bar_data: term(),
          git_syncing: boolean(),
          git_toast: GitToast.t(),
          search: Search.t(),
          last_input_seq: non_neg_integer(),
          frame_seq: non_neg_integer() | nil,
          force_keyframe?: boolean(),
          acknowledgement_required?: boolean(),
          surface_placements: [MingaEditor.Layout.SurfaceRegistry.wire_placement()],
          gui?: boolean(),
          line_spacing: number() | nil,
          cursor_animate: boolean() | nil,
          config_state: Minga.RenderModel.UI.ConfigState.t() | nil,
          link_cursor: boolean()
        }

  @enforce_keys [:port_manager, :capabilities, :theme, :font_registry, :windows, :layout, :shell]
  defstruct port_manager: nil,
            capabilities: nil,
            theme: nil,
            font_registry: nil,
            windows: nil,
            layout: nil,
            shell_id: :traditional,
            shell: nil,
            shell_state: nil,
            tab_bar: nil,
            buffers: nil,
            viewport: nil,
            file_tree: nil,
            highlight: nil,
            agent_ui: nil,
            launchpad: nil,
            completion: nil,
            keymap_scope: :editor,
            editing: nil,
            message_store: nil,
            notifications: NotificationCenter.new(),
            sidebar_registry: MingaEditor.Extension.Sidebar.default_table(),
            title: "Minga",
            status_bar_data: nil,
            git_syncing: false,
            git_toast: %GitToast{},
            search: %Search{},
            last_input_seq: 0,
            frame_seq: nil,
            force_keyframe?: false,
            acknowledgement_required?: false,
            surface_placements: [],
            gui?: false,
            line_spacing: nil,
            cursor_animate: nil,
            config_state: nil,
            link_cursor: false

  @doc "Builds an emit context from editor state or its render-pipeline transfer value."
  @spec from_editor_state(State.t() | Input.t()) :: t()
  def from_editor_state(%State{} = state) do
    state |> Input.from_editor_state() |> from_editor_state()
  end

  def from_editor_state(
        %Input{shell_id: shell_id, shell: shell, shell_state: shell_state} = input
      ) do
    build(input, shell_id, shell, shell_state)
  end

  @spec build(Input.t(), atom(), module(), term()) :: t()
  defp build(state, shell_id, shell, shell_state) do
    title = compute_title(state, shell, shell_state)
    gui? = MingaEditor.Frontend.gui?(state.capabilities)

    %__MODULE__{
      port_manager: state.port_manager,
      capabilities: state.capabilities,
      theme: state.theme,
      font_registry: Map.get(state, :font_registry, FontRegistry.new()),
      windows: state.workspace.windows,
      layout: MingaEditor.Layout.get(state),
      shell_id: shell_id,
      shell: shell,
      shell_state: shell_state,
      tab_bar: Map.get(shell_state, :tab_bar),
      buffers: state.workspace.buffers,
      viewport: state.terminal_viewport,
      file_tree: state.workspace.file_tree,
      highlight: state.highlighting,
      agent_ui: state.workspace.agent_ui,
      # Strict like every sibling field: a snapshot path that drops the
      # launchpad key must fail loudly, not render the launchpad hidden.
      launchpad: state.workspace.launchpad,
      completion: MingaEditor.Shell.Traditional.ModalWorkflow.completion(state),
      keymap_scope: state.workspace.keymap_scope,
      editing: state.workspace.editing,
      message_store: state.message_store,
      notifications: state.notifications,
      sidebar_registry:
        Map.get(state, :sidebar_registry, MingaEditor.Extension.Sidebar.default_table()),
      title: title,
      status_bar_data: state.status_bar_data,
      git_syncing: state.git_syncing,
      git_toast: Map.get(shell_state, :git_toast),
      search: state.workspace.search,
      last_input_seq: Map.get(state, :last_input_seq, 0),
      frame_seq: Map.get(state, :frame_seq),
      force_keyframe?: Map.get(state, :force_keyframe?, false),
      acknowledgement_required?: state.backend != :headless and not is_nil(state.port_manager),
      # The single per-frame surface layout authority (#2268), already projected
      # to wire shape by the registry. Derived from the same focus tree mouse
      # routing hit-tests against, so the emitted placement rect for every surface
      # equals its BEAM hit-test rect by construction. The encoder consumes these
      # plain maps and stays free of any MingaEditor dependency.
      surface_placements: MingaEditor.Layout.SurfaceRegistry.wire_placements(state),
      # GUI config settings carried in-frame as semantic models (#2119). These are
      # GUI-only renderer preferences plus the native settings snapshot; they ride
      # inside the frame transaction so a late-attaching client's keyframe carries
      # them. The render pipeline Input pre-computes them from EditorState (a cheap
      # ETS read for line_spacing/cursor_animate, a cached field for config_state)
      # so the emit stage never reaches back into the config or keymap servers.
      gui?: gui?,
      line_spacing: gui_only(gui?, Map.get(state, :line_spacing)),
      cursor_animate: gui_only(gui?, Map.get(state, :cursor_animate)),
      config_state: gui_only(gui?, Map.get(state, :gui_config_state)),
      # The pointing-hand cursor is GUI-only; a non-nil Cmd/Ctrl-hover link range
      # means a navigable symbol is under the pointer (#2630).
      link_cursor: gui? and state.workspace.cmd_hover_link != nil
    }
  end

  @spec gui_only(boolean(), value) :: value | nil when value: var
  defp gui_only(true, value), do: value
  defp gui_only(false, _value), do: nil

  @spec compute_title(State.t() | Input.t(), module(), term()) :: String.t()
  defp compute_title(state, shell, shell_state) do
    case shell.gui_payload(state) do
      nil ->
        compute_standard_title(state, shell_state)

      other ->
        Minga.Log.warning(
          :render,
          "Unsupported GUI shell payload #{inspect(other)}; using standard title"
        )

        compute_standard_title(state, shell_state)
    end
  end

  @spec compute_standard_title(State.t() | Input.t(), term()) :: String.t()
  defp compute_standard_title(state, shell_state) do
    if MingaEditor.Frontend.gui?(state.capabilities) do
      MingaEditor.Title.format_gui(state)
    else
      format = Minga.Config.get(:title_format) |> to_string()
      title = MingaEditor.Title.format(state, format)
      tb = is_map(shell_state) && Map.get(shell_state, :tab_bar)

      if tb && TabBar.any_attention?(tb) do
        "[!] " <> title
      else
        title
      end
    end
  end
end
