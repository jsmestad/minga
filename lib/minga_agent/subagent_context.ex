defmodule MingaAgent.SubagentContext do
  @moduledoc """
  Configuration context inherited by child subagent sessions.

  The subagent tool uses this struct to carry the parent session's provider, model, thinking level, active skills, and project root across module boundaries without relying on a raw map shape.
  """

  @typedoc "Inherited context for a child subagent session."
  @type t :: %__MODULE__{
          provider_module: module(),
          provider_name: String.t(),
          model: String.t() | nil,
          thinking_level: String.t() | nil,
          active_skill_names: [String.t()],
          project_root: String.t() | nil
        }

  @enforce_keys [
    :provider_module,
    :provider_name,
    :model,
    :thinking_level,
    :active_skill_names,
    :project_root
  ]
  defstruct provider_module: MingaAgent.Providers.Native,
            provider_name: "native",
            model: nil,
            thinking_level: nil,
            active_skill_names: [],
            project_root: nil

  @doc "Returns the default context used when no parent session is available."
  @spec default() :: t()
  def default do
    %__MODULE__{
      provider_module: MingaAgent.Providers.Native,
      provider_name: "native",
      model: nil,
      thinking_level: nil,
      active_skill_names: [],
      project_root: nil
    }
  end
end
