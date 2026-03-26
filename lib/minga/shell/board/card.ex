defmodule Minga.Shell.Board.Card do
  @moduledoc """
  A card on The Board representing an agent session or manual workspace.

  Each card carries a workspace snapshot (buffers, editing state) that
  gets restored when the user zooms in and captured when they zoom out.
  This is the same pattern as tab context snapshots in Shell.Traditional.

  The "You" card has `session: nil` and provides the traditional editing
  experience without an agent.

  ## Status lifecycle

      :idle → :working → :iterating → :done
                  ↓           ↓
              :needs_you   :errored

  `:working` means the agent is actively generating. `:iterating` means
  it's running tests or linter feedback loops. `:needs_you` means it
  hit a wall and needs human input (approval, clarifying question).
  """

  @type status :: :idle | :working | :iterating | :needs_you | :done | :errored

  @type id :: pos_integer()

  @type t :: %__MODULE__{
          id: id(),
          session: pid() | nil,
          workspace: map() | nil,
          task: String.t(),
          status: status(),
          model: String.t() | nil,
          created_at: DateTime.t(),
          recent_files: [String.t()]
        }

  @enforce_keys [:id, :task]
  defstruct id: nil,
            session: nil,
            workspace: nil,
            task: "",
            status: :idle,
            model: nil,
            created_at: nil,
            recent_files: []

  @doc "Creates a new card with the given attributes."
  @spec new(id(), keyword()) :: t()
  def new(id, attrs \\ []) do
    %__MODULE__{
      id: id,
      task: Keyword.get(attrs, :task, ""),
      session: Keyword.get(attrs, :session),
      model: Keyword.get(attrs, :model),
      workspace: Keyword.get(attrs, :workspace),
      status: Keyword.get(attrs, :status, :idle),
      created_at: DateTime.utc_now(),
      recent_files: Keyword.get(attrs, :recent_files, [])
    }
  end

  @doc "Transitions the card to a new status."
  @spec set_status(t(), status()) :: t()
  def set_status(%__MODULE__{} = card, status) do
    %{card | status: status}
  end

  @doc "Attaches an agent session PID to the card."
  @spec attach_session(t(), pid()) :: t()
  def attach_session(%__MODULE__{} = card, pid) when is_pid(pid) do
    %{card | session: pid, status: :working}
  end

  @doc "Stores a workspace snapshot on the card."
  @spec store_workspace(t(), map()) :: t()
  def store_workspace(%__MODULE__{} = card, workspace) when is_map(workspace) do
    %{card | workspace: workspace}
  end

  @doc "Clears the stored workspace snapshot."
  @spec clear_workspace(t()) :: t()
  def clear_workspace(%__MODULE__{} = card) do
    %{card | workspace: nil}
  end

  @doc "Updates the list of recently touched files."
  @spec set_recent_files(t(), [String.t()]) :: t()
  def set_recent_files(%__MODULE__{} = card, files) when is_list(files) do
    %{card | recent_files: files}
  end

  @doc "Returns true if this is the 'You' card (no agent session)."
  @spec you_card?(t()) :: boolean()
  def you_card?(%__MODULE__{session: nil}), do: true
  def you_card?(%__MODULE__{}), do: false
end
