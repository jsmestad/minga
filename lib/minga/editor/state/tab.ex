defmodule Minga.Editor.State.Tab do
  @moduledoc """
  A single tab in the tab bar.

  Each tab has a unique id, a kind (`:file` or `:agent`), a display label,
  and a context map that stores snapshotted per-tab state when the tab is
  inactive. The active tab's context is "live" on EditorState; inactive
  tabs carry a frozen snapshot that gets restored when you switch to them.

  ## Context format

  The canonical context is a flat map with per-tab fields (buffers, windows,
  vim state, viewport, etc.) stored directly. Legacy contexts with nested
  structure are auto-migrated on first restore.
  """

  # Tab contexts store per-tab fields directly as flat maps.

  @typedoc "Unique tab identifier."
  @type id :: pos_integer()

  @typedoc "Tab kind."
  @type kind :: :file | :agent

  @typedoc """
  Snapshotted per-tab state.

  The context stores per-tab fields directly (buffers, windows, mode, etc.).
  Empty context means a brand-new tab.

  Legacy contexts with nested structure (old snapshot format) or
  bare fields (oldest format) are auto-migrated on first restore.
  """
  @type context :: %{
          optional(:keymap_scope) => atom(),
          optional(:buffers) => term(),
          optional(:windows) => term(),
          optional(:file_tree) => term(),
          optional(:viewport) => term(),
          optional(:mouse) => term(),
          optional(:highlight) => term(),
          optional(:lsp_pending) => term(),
          optional(:completion) => term(),
          optional(:completion_trigger) => term(),
          optional(:injection_ranges) => term(),
          optional(:search) => term(),
          optional(:pending_conflict) => term(),
          optional(:vim) => Minga.Editor.VimState.t(),
          # Legacy fields kept for migration compatibility:
          optional(:mode) => atom(),
          optional(:mode_state) => term(),
          optional(:reg) => term(),
          optional(:marks) => term(),
          optional(:last_jump_pos) => term(),
          optional(:last_find_char) => term(),
          optional(:change_recorder) => term(),
          optional(:macro_recorder) => term()
        }

  @typedoc "Agent tab status (nil for file tabs)."
  @type agent_status :: :idle | :thinking | :tool_executing | :error | nil

  @typedoc "Workspace group id. 0 = manual/ungrouped workspace."
  @type group_id :: non_neg_integer()

  @typedoc "A tab."
  @type t :: %__MODULE__{
          id: id(),
          kind: kind(),
          label: String.t(),
          context: context(),
          session: pid() | nil,
          agent_status: agent_status(),
          attention: boolean(),
          group_id: group_id()
        }

  @enforce_keys [:id, :kind]
  defstruct id: nil,
            kind: nil,
            label: "",
            context: %{},
            session: nil,
            agent_status: nil,
            attention: false,
            group_id: 0

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

  @doc "Sets the agent status on a tab (for tab bar rendering)."
  @spec set_agent_status(t(), agent_status()) :: t()
  def set_agent_status(%__MODULE__{} = tab, status) do
    %{tab | agent_status: status}
  end

  @doc "Sets the attention flag (agent needs user input)."
  @spec set_attention(t(), boolean()) :: t()
  def set_attention(%__MODULE__{} = tab, value) when is_boolean(value) do
    %{tab | attention: value}
  end

  @doc "Sets the workspace group id."
  @spec set_group(t(), group_id()) :: t()
  def set_group(%__MODULE__{} = tab, group_id) when is_integer(group_id) and group_id >= 0 do
    %{tab | group_id: group_id}
  end
end
