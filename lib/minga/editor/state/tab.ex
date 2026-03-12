defmodule Minga.Editor.State.Tab do
  @moduledoc """
  A single tab in the tab bar.

  Each tab has a unique id, a kind (`:file` or `:agent`), a display label,
  and a context map that stores snapshotted per-tab state when the tab is
  inactive. The active tab's context is "live" on EditorState; inactive
  tabs carry a frozen snapshot that gets restored when you switch to them.

  ## Context format

  The canonical context has three fields: `surface_module`, `surface_state`,
  and `keymap_scope`. All per-view state (buffers, windows, mode, agent, etc.)
  lives inside `surface_state`. Legacy contexts with per-field snapshots are
  auto-migrated on first restore.
  """

  # Legacy context type aliases removed. Surface state carries all per-view data.

  @typedoc "Unique tab identifier."
  @type id :: pos_integer()

  @typedoc "Tab kind."
  @type kind :: :file | :agent

  @typedoc """
  Snapshotted per-tab state.

  The canonical context has three fields: `surface_module`, `surface_state`,
  and `keymap_scope`. All per-view state (buffers, windows, mode, etc.)
  lives inside `surface_state`. Empty context means a brand-new tab.

  Legacy contexts with per-field snapshots (windows, mode, active_buffer,
  etc.) are auto-migrated to the canonical format on first restore.
  """
  @type context :: %{
          optional(:surface_module) => module() | nil,
          optional(:surface_state) => term() | nil,
          optional(:keymap_scope) => atom()
        }

  @typedoc "Opaque surface state stored on the tab when it's inactive."
  @type surface_state :: term() | nil

  @typedoc "A tab."
  @type t :: %__MODULE__{
          id: id(),
          kind: kind(),
          label: String.t(),
          context: context(),
          session: pid() | nil,
          surface_module: module() | nil,
          surface_state: surface_state()
        }

  @enforce_keys [:id, :kind]
  defstruct id: nil,
            kind: nil,
            label: "",
            context: %{},
            session: nil,
            surface_module: nil,
            surface_state: nil

  @doc "Creates a new file tab."
  @spec new_file(id(), String.t()) :: t()
  def new_file(id, label \\ "") when is_integer(id) and id > 0 do
    %__MODULE__{id: id, kind: :file, label: label}
  end

  @doc "Creates a new agent tab."
  @spec new_agent(id(), String.t()) :: t()
  def new_agent(id, label \\ "Agent") when is_integer(id) and id > 0 do
    %__MODULE__{id: id, kind: :agent, label: label}
  end

  @doc "Updates the tab's label."
  @spec set_label(t(), String.t()) :: t()
  def set_label(%__MODULE__{} = tab, label) when is_binary(label) do
    %{tab | label: label}
  end

  @doc "Stores a context snapshot into the tab."
  @spec set_context(t(), context()) :: t()
  def set_context(%__MODULE__{} = tab, context) when is_map(context) do
    %{tab | context: context}
  end

  @doc "Returns true if this is a file tab."
  @spec file?(t()) :: boolean()
  def file?(%__MODULE__{kind: :file}), do: true
  def file?(%__MODULE__{}), do: false

  @doc "Returns true if this is an agent tab."
  @spec agent?(t()) :: boolean()
  def agent?(%__MODULE__{kind: :agent}), do: true
  def agent?(%__MODULE__{}), do: false

  @doc "Sets the session pid for an agent tab."
  @spec set_session(t(), pid() | nil) :: t()
  def set_session(%__MODULE__{} = tab, pid) do
    %{tab | session: pid}
  end
end
