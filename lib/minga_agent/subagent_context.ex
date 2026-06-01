defmodule MingaAgent.SubagentContext do
  @moduledoc """
  Configuration context inherited by child subagent sessions.

  The subagent tool uses this struct to carry the parent session's provider, model, thinking level, active skills, and project root across module boundaries without relying on a raw map shape.
  """

  @typedoc "Inherited context for a child subagent session."
  @type t :: %__MODULE__{
          provider_module: module(),
          provider_name: String.t(),
          provider_id: String.t(),
          provider_source: Minga.Extension.ContributionCleanup.contribution_source(),
          model: String.t() | nil,
          thinking_level: String.t() | nil,
          active_skill_names: [String.t()],
          project_root: String.t() | nil
        }

  @enforce_keys [:provider_module, :provider_name]
  defstruct [
    :provider_module,
    :provider_name,
    :thinking_level,
    :project_root,
    provider_id: "native",
    provider_source: :builtin,
    model: nil,
    active_skill_names: []
  ]

  @doc "Builds a context from the given attributes."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc "Returns the default context used when no parent session is available."
  @spec default() :: t()
  def default do
    new(
      provider_module: MingaAgent.Providers.Native,
      provider_name: "native",
      provider_id: "native",
      provider_source: :builtin,
      model: nil,
      thinking_level: nil,
      active_skill_names: [],
      project_root: nil
    )
  end
end
