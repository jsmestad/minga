defmodule MingaEditor.State.Tab.Context do
  @moduledoc """
  Typed per-tab workspace snapshot stored on `MingaEditor.State.Tab`.

  Contexts replace the old free-form map while still accepting legacy maps at API boundaries. `present_fields` records which workspace fields were actually present in a legacy map so partial migration inputs do not overwrite live workspace state with nil defaults.
  """

  alias Minga.Keymap.Scope
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Dired, as: DiredState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Mouse
  alias MingaEditor.State.Search
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Session.State, as: SessionState

  @version 1

  @workspace_fields [
    :keymap_scope,
    :buffers,
    :windows,
    :file_tree,
    :dired,
    :viewport,
    :mouse,
    :lsp_pending,
    :search,
    :editing,
    :document_highlights
  ]

  @typedoc "Workspace fields carried by a tab context."
  @type field_name ::
          :keymap_scope
          | :buffers
          | :windows
          | :file_tree
          | :dired
          | :viewport
          | :mouse
          | :lsp_pending
          | :search
          | :editing
          | :document_highlights

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
          dired: DiredState.t() | nil,
          viewport: Viewport.t() | nil,
          mouse: Mouse.t() | nil,
          lsp_pending: %{reference() => atom() | tuple()} | nil,
          search: Search.t() | nil,
          editing: VimState.t() | nil,
          document_highlights: [document_highlight()] | nil
        }

  defstruct version: @version,
            present_fields: [],
            keymap_scope: nil,
            buffers: nil,
            windows: nil,
            file_tree: nil,
            dired: nil,
            viewport: nil,
            mouse: nil,
            lsp_pending: nil,
            search: nil,
            editing: nil,
            document_highlights: nil

  @doc "Returns the workspace field names represented by this context."
  @spec field_names() :: [field_name()]
  def field_names, do: @workspace_fields

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
      dired: ws.dired,
      viewport: ws.viewport,
      mouse: ws.mouse,
      lsp_pending: ws.lsp_pending,
      search: ws.search,
      editing: editing,
      document_highlights: ws.document_highlights,
      present_fields: @workspace_fields
    }
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
    fields = fetch_present_fields(map) || @workspace_fields

    Enum.reduce(fields, context, fn field, acc ->
      case fetch_field(map, field) do
        {:ok, value} -> put_valid_field(acc, field, value)
        :error -> acc
      end
    end)
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

  @doc "Returns a context with the dead buffer removed from its `buffers` snapshot when present."
  @spec scrub_buffer(t() | legacy(), pid()) :: t()
  def scrub_buffer(context, pid) do
    context
    |> from_map()
    |> scrub_context_buffer(pid)
  end

  @spec scrub_context_buffer(t(), pid()) :: t()
  defp scrub_context_buffer(%__MODULE__{buffers: %Buffers{} = buffers} = context, pid) do
    put_field(context, :buffers, Buffers.remove(buffers, pid))
  end

  defp scrub_context_buffer(%__MODULE__{} = context, _pid), do: context

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
  defp valid_field?(:dired, %DiredState{}), do: true
  defp valid_field?(:viewport, %Viewport{}), do: true
  defp valid_field?(:mouse, %Mouse{}), do: true
  defp valid_field?(:lsp_pending, value) when is_map(value), do: true
  defp valid_field?(:search, %Search{}), do: true
  defp valid_field?(:editing, %VimState{}), do: true
  defp valid_field?(:document_highlights, nil), do: true
  defp valid_field?(:document_highlights, value) when is_list(value), do: true
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

  @spec fetch_any(map(), [atom() | String.t()]) :: {:ok, term()} | :error
  defp fetch_any(map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_any(map, rest)
    end
  end

  defp fetch_any(_map, []), do: :error
end
