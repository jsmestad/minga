defmodule MingaEditor.State.Tab.Context do
  @moduledoc """
  Typed per-tab workspace snapshot stored on `MingaEditor.State.Tab`.

  Contexts replace the old free-form map while still accepting legacy maps at API boundaries. `present_fields` records which workspace fields were actually present in a legacy map so partial migration inputs do not overwrite live workspace state with nil defaults.
  """

  alias Minga.Keymap.Scope
  alias MingaEditor.Agent.UIState
  alias MingaEditor.FeatureState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Mouse
  alias MingaEditor.State.Search
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  @version 1

  @snapshot_fields [
    :keymap_scope,
    :buffers,
    :windows,
    :file_tree,
    :viewport,
    :mouse,
    :lsp_pending,
    :search,
    :editing,
    :feature_state,
    :document_highlights
  ]

  @shared_fields [:agent_ui]

  @workspace_fields @snapshot_fields ++ @shared_fields

  # Transient pointer state that is deliberately NOT carried per tab. The
  # Cmd/Ctrl-hover go-to-definition link preview (#2630) tracks the symbol under
  # the mouse for the current frame only; snapshotting it would restore a stale
  # underline (and GUI hand cursor) against the wrong buffer on tab switch, which
  # is exactly what the clear-on-transition design avoids. Listed here so the
  # "tab context carries every session workspace field" guard stays meaningful:
  # a new NON-transient workspace field still fails that test until it is added
  # to @snapshot_fields/@shared_fields above.
  # :launchpad (#2689) is also transient: it exists only while the workspace
  # has zero buffers, and entering the empty state removes all file tabs, so
  # no tab snapshot could meaningfully carry it.
  @transient_fields [:hover_observation, :launchpad]

  @typedoc "Workspace fields carried by a tab context."
  @type field_name ::
          :keymap_scope
          | :buffers
          | :windows
          | :file_tree
          | :viewport
          | :mouse
          | :lsp_pending
          | :search
          | :editing
          | :feature_state
          | :document_highlights
          | :agent_ui

  @typedoc "Legacy map persisted or built before tab contexts became typed structs."
  @type legacy :: map()

  @typedoc "A document highlight range from the LSP server."
  @type document_highlight :: Minga.LSP.DocumentHighlight.t()

  @type t :: %__MODULE__{
          version: pos_integer(),
          present_fields: [field_name()],
          keymap_scope: Scope.scope_name() | nil,
          buffers: Buffers.t() | nil,
          windows: Windows.t() | nil,
          file_tree: FileTreeState.t() | nil,
          viewport: Viewport.t() | nil,
          mouse: Mouse.t() | nil,
          lsp_pending: %{reference() => atom() | tuple()} | nil,
          search: Search.t() | nil,
          editing: VimState.t() | nil,
          feature_state: FeatureState.t() | nil,
          document_highlights: [document_highlight()] | nil,
          agent_ui: UIState.t() | nil
        }

  defstruct version: @version,
            present_fields: [],
            keymap_scope: nil,
            buffers: nil,
            windows: nil,
            file_tree: nil,
            viewport: nil,
            mouse: nil,
            lsp_pending: nil,
            search: nil,
            editing: nil,
            feature_state: nil,
            document_highlights: nil,
            agent_ui: nil

  @doc "Returns the workspace field names represented by this context."
  @spec field_names() :: [field_name()]
  def field_names, do: @workspace_fields

  @doc """
  Returns workspace fields intentionally excluded from per-tab snapshotting.

  These are transient pointer/frame state (#2630), never persisted or restored.
  Together with `field_names/0` they must account for every `Session.State`
  field; the `feature_state_test` guard enforces that.
  """
  @spec transient_fields() :: [atom()]
  def transient_fields, do: @transient_fields

  @doc "Returns an empty context for a brand-new tab with no saved workspace yet."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Returns true when the context has no workspace fields to restore."
  @spec empty?(t() | legacy()) :: boolean()
  def empty?(%__MODULE__{} = context), do: map_size(to_workspace_map(context)) == 0

  def empty?(context) when is_map(context) do
    case fetch_present_fields(context) do
      nil -> map_size(context) == 0
      _fields -> context |> from_map() |> empty?()
    end
  end

  @doc "Creates a tab context directly from a workspace struct, without intermediate map conversion."
  @spec from_workspace(SessionState.t()) :: t()
  def from_workspace(%SessionState{} = ws) do
    editing = VimState.normalize(ws.editing)

    %__MODULE__{
      version: @version,
      keymap_scope: ws.keymap_scope,
      buffers: ws.buffers,
      windows: ws.windows,
      file_tree: ws.file_tree,
      viewport: ws.viewport,
      mouse: ws.mouse,
      lsp_pending: ws.lsp_pending,
      search: ws.search,
      editing: editing,
      feature_state: ws.feature_state,
      document_highlights: ws.document_highlights,
      present_fields: @snapshot_fields
    }
  end

  @doc "Captures a complete tab snapshot, including a non-default shared agent projection."
  @spec snapshot(SessionState.t()) :: t()
  def snapshot(%SessionState{} = workspace) do
    context = from_workspace(workspace)

    if workspace.agent_ui == UIState.new() do
      context
    else
      put_field(context, :agent_ui, workspace.agent_ui)
    end
  end

  @doc "Builds the initial context for a new file tab from the current workspace and viewport."
  @spec new_file(SessionState.t(), Viewport.t()) :: t()
  def new_file(%SessionState{} = workspace, %Viewport{} = viewport) do
    buffer = workspace.buffers.active
    windows = file_windows(workspace.windows.next_id, buffer, viewport)

    from_workspace_values(
      :editor,
      %Buffers{
        active: buffer,
        list: if(buffer, do: [buffer], else: []),
        active_index: workspace.buffers.active_index
      },
      windows,
      viewport,
      workspace.file_tree.project_root
    )
  end

  @doc "Builds the initial context for a semantic agent tab."
  @spec new_agent(Viewport.t(), String.t() | nil) :: t()
  def new_agent(%Viewport{} = viewport, project_root)
      when is_binary(project_root) or is_nil(project_root) do
    rows = max(viewport.rows, 1)
    cols = max(viewport.cols, 1)
    window_id = 1
    window = Window.new_agent_chat(window_id, rows, cols)

    windows = %Windows{
      tree: WindowTree.new(window_id),
      map: %{window_id => window},
      active: window_id,
      next_id: window_id + 1
    }

    new_agent(viewport, project_root, windows)
  end

  @doc "Builds an agent context around an already-constructed semantic window set."
  @spec new_agent(Viewport.t(), String.t() | nil, Windows.t()) :: t()
  def new_agent(%Viewport{} = viewport, project_root, %Windows{} = windows)
      when is_binary(project_root) or is_nil(project_root) do
    from_workspace_values(:agent, %Buffers{}, windows, viewport, project_root)
  end

  @doc "Returns the active buffer pid represented by this context, when present."
  @spec active_buffer_pid(t() | legacy()) :: pid() | nil
  def active_buffer_pid(context) when is_map(context) do
    case to_workspace_map(context) do
      %{buffers: %Buffers{active: active}} when is_pid(active) -> active
      _other -> nil
    end
  end

  @doc "Returns live buffer pids represented by this context."
  @spec buffer_pids(t() | legacy()) :: [pid()]
  def buffer_pids(context) when is_map(context) do
    case to_workspace_map(context) do
      %{buffers: %Buffers{active: active, list: buffers}} ->
        [active | buffers]
        |> Enum.filter(&is_pid/1)
        |> Enum.uniq()

      _other ->
        []
    end
  end

  @doc deprecated:
         "Use from_workspace/1 for struct inputs. This remains for legacy map inputs only."
  @spec from_workspace_map(map()) :: t()
  def from_workspace_map(map) when is_map(map), do: from_map(map)

  @doc "Normalizes a legacy context map into a typed context struct."
  @spec from_map(t() | legacy()) :: t()
  def from_map(%__MODULE__{} = context), do: context

  def from_map(map) when is_map(map) do
    context = %__MODULE__{version: fetch_version(map)}
    fields = filter_snapshot_fields(fetch_present_fields(map) || @snapshot_fields)

    fields
    |> Enum.reduce(context, fn field, acc ->
      case fetch_field(map, field) do
        {:ok, value} -> put_valid_field(acc, field, value)
        :error -> acc
      end
    end)
    |> migrate_legacy_file_tree(map)
  end

  @doc "Returns a context with valid workspace field overrides applied."
  @spec put_fields(t(), map() | keyword()) :: t()
  def put_fields(%__MODULE__{} = context, attrs) when is_list(attrs) do
    put_fields(context, Map.new(attrs))
  end

  def put_fields(%__MODULE__{} = context, attrs) when is_map(attrs) do
    Enum.reduce(@workspace_fields, context, fn field, acc ->
      case fetch_field(attrs, field) do
        {:ok, value} -> put_valid_field(acc, field, value)
        :error -> acc
      end
    end)
  end

  @doc "Returns a workspace map containing only fields present in this context."
  @spec to_workspace_map(t() | legacy()) :: map()
  def to_workspace_map(%__MODULE__{} = context) do
    context.present_fields
    |> normalize_present_fields()
    |> Enum.reduce(%{}, fn field, acc -> put_workspace_field(acc, context, field) end)
  end

  def to_workspace_map(map) when is_map(map) do
    map
    |> from_map()
    |> to_workspace_map()
  end

  @doc "Returns a context with every exact reference to the dead buffer retired when present."
  @spec scrub_buffer(t() | legacy(), pid()) :: t()
  def scrub_buffer(context, pid) do
    context
    |> from_map()
    |> scrub_context_buffer(pid)
    |> scrub_context_prompt_buffer(pid)
  end

  @spec file_windows(pos_integer(), pid() | nil, Viewport.t()) :: Windows.t()
  defp file_windows(_window_id, nil, %Viewport{}), do: %Windows{}

  defp file_windows(window_id, buffer, %Viewport{} = viewport) when is_pid(buffer) do
    window = Window.new(window_id, buffer, max(viewport.rows, 1), max(viewport.cols, 1))

    %Windows{
      tree: WindowTree.new(window_id),
      map: %{window_id => window},
      active: window_id,
      next_id: window_id + 1
    }
  end

  @spec from_workspace_values(
          Scope.scope_name(),
          Buffers.t(),
          Windows.t(),
          Viewport.t(),
          String.t() | nil
        ) :: t()
  defp from_workspace_values(scope, buffers, windows, viewport, project_root) do
    %__MODULE__{
      version: @version,
      present_fields: @snapshot_fields,
      keymap_scope: scope,
      buffers: buffers,
      windows: windows,
      file_tree: %FileTreeState{project_root: project_root},
      viewport: viewport,
      mouse: %Mouse{},
      lsp_pending: %{},
      search: %Search{},
      editing: VimState.new(),
      feature_state: FeatureState.new(),
      document_highlights: nil
    }
  end

  @spec scrub_context_buffer(t(), pid()) :: t()
  defp scrub_context_buffer(%__MODULE__{buffers: %Buffers{} = buffers} = context, pid) do
    put_field(context, :buffers, Buffers.remove(buffers, pid))
  end

  defp scrub_context_buffer(%__MODULE__{} = context, _pid), do: context

  @spec scrub_context_prompt_buffer(t(), pid()) :: t()
  defp scrub_context_prompt_buffer(%__MODULE__{agent_ui: %UIState{} = agent_ui} = context, pid) do
    put_field(context, :agent_ui, UIState.retire_prompt_buffer(agent_ui, pid))
  end

  defp scrub_context_prompt_buffer(%__MODULE__{} = context, _pid), do: context

  @spec migrate_legacy_file_tree(t(), map()) :: t()
  defp migrate_legacy_file_tree(%__MODULE__{} = context, map) do
    context
    |> migrate_legacy_direct_file_tree(map)
    |> migrate_legacy_feature_state_file_tree()
    |> drop_legacy_feature_state_file_tree()
  end

  @spec migrate_legacy_direct_file_tree(t(), map()) :: t()
  defp migrate_legacy_direct_file_tree(%__MODULE__{} = context, map) do
    case fetch_legacy_file_tree(map) do
      {:ok, %FileTreeState{} = file_tree} -> put_valid_field(context, :file_tree, file_tree)
      _ -> context
    end
  end

  @spec migrate_legacy_feature_state_file_tree(t()) :: t()
  defp migrate_legacy_feature_state_file_tree(%__MODULE__{file_tree: %FileTreeState{}} = context),
    do: context

  defp migrate_legacy_feature_state_file_tree(
         %__MODULE__{feature_state: %FeatureState{} = feature_state} = context
       ) do
    case FeatureState.fetch(feature_state, :builtin, :file_tree) do
      {:ok, %FileTreeState{} = file_tree} -> put_valid_field(context, :file_tree, file_tree)
      _ -> context
    end
  end

  defp migrate_legacy_feature_state_file_tree(%__MODULE__{} = context), do: context

  @spec drop_legacy_feature_state_file_tree(t()) :: t()
  defp drop_legacy_feature_state_file_tree(
         %__MODULE__{feature_state: %FeatureState{} = feature_state} = context
       ) do
    put_valid_field(
      context,
      :feature_state,
      FeatureState.drop(feature_state, :builtin, :file_tree)
    )
  end

  defp drop_legacy_feature_state_file_tree(%__MODULE__{} = context), do: context

  @spec put_valid_field(t(), field_name(), term()) :: t()
  defp put_valid_field(%__MODULE__{} = context, field, value) do
    if valid_field?(field, value), do: put_field(context, field, value), else: context
  end

  @spec put_field(t(), field_name(), term()) :: t()
  defp put_field(%__MODULE__{present_fields: present_fields} = context, field, value) do
    context
    |> Map.put(field, value)
    |> Map.put(:present_fields, add_present_field(present_fields, field))
  end

  @spec add_present_field([field_name()], field_name()) :: [field_name()]
  defp add_present_field(present_fields, field) do
    if field in present_fields, do: present_fields, else: [field | present_fields]
  end

  @spec put_workspace_field(map(), t(), field_name()) :: map()
  defp put_workspace_field(acc, %__MODULE__{} = context, field) do
    value = Map.fetch!(context, field)
    if valid_field?(field, value), do: Map.put(acc, field, value), else: acc
  end

  @spec valid_field?(field_name(), term()) :: boolean()
  defp valid_field?(:keymap_scope, value) when is_atom(value), do: value in Scope.all_scopes()
  defp valid_field?(:keymap_scope, _value), do: false
  defp valid_field?(:buffers, %Buffers{}), do: true
  defp valid_field?(:windows, %Windows{}), do: true
  defp valid_field?(:file_tree, %FileTreeState{}), do: true
  defp valid_field?(:viewport, %Viewport{}), do: true
  defp valid_field?(:mouse, %Mouse{}), do: true
  defp valid_field?(:lsp_pending, value) when is_map(value), do: true
  defp valid_field?(:search, %Search{}), do: true
  defp valid_field?(:editing, %VimState{}), do: true
  defp valid_field?(:feature_state, %FeatureState{}), do: true
  defp valid_field?(:document_highlights, nil), do: true
  defp valid_field?(:document_highlights, value) when is_list(value), do: true
  defp valid_field?(:agent_ui, %UIState{}), do: true
  defp valid_field?(_field, _value), do: false

  @spec fetch_version(map()) :: pos_integer()
  defp fetch_version(map) do
    case fetch_any(map, [:version, "version"]) do
      {:ok, version} when is_integer(version) and version > 0 -> version
      _ -> @version
    end
  end

  @spec fetch_present_fields(map()) :: [field_name()] | nil
  defp fetch_present_fields(map) do
    case fetch_any(map, [:present_fields, "present_fields"]) do
      {:ok, fields} when is_list(fields) -> normalize_present_fields(fields)
      _ -> nil
    end
  end

  @spec filter_snapshot_fields([field_name()]) :: [field_name()]
  defp filter_snapshot_fields(fields) do
    Enum.filter(fields, &(&1 in @snapshot_fields))
  end

  @spec normalize_present_fields([term()]) :: [field_name()]
  defp normalize_present_fields(fields) do
    Enum.flat_map(fields, &normalize_present_field/1)
  end

  @spec normalize_present_field(term()) :: [field_name()]
  defp normalize_present_field(field) when is_atom(field) do
    if field in @workspace_fields, do: [field], else: []
  end

  defp normalize_present_field(field) when is_binary(field) do
    case Enum.find(@workspace_fields, &(Atom.to_string(&1) == field)) do
      nil -> []
      workspace_field -> [workspace_field]
    end
  end

  defp normalize_present_field(_field), do: []

  @spec fetch_field(map(), field_name()) :: {:ok, term()} | :error
  defp fetch_field(map, :editing), do: fetch_any(map, [:editing, "editing", :vim, "vim"])
  defp fetch_field(map, field), do: fetch_any(map, [field, Atom.to_string(field)])

  @spec fetch_legacy_file_tree(map()) :: {:ok, term()} | :error
  defp fetch_legacy_file_tree(map), do: fetch_any(map, [:file_tree, "file_tree"])

  @spec fetch_any(map(), [atom() | String.t()]) :: {:ok, term()} | :error
  defp fetch_any(map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_any(map, rest)
    end
  end

  defp fetch_any(_map, []), do: :error
end
