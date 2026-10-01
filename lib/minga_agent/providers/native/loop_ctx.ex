defmodule MingaAgent.Providers.Native.LoopCtx do
  @moduledoc "Immutable parameters captured for one native agent turn loop."

  alias MingaAgent.ModelSelection
  alias MingaAgent.ProjectView
  alias MingaAgent.Session.Request

  @enforce_keys [
    :provider_pid,
    :request,
    :selection,
    :config,
    :tools,
    :project_root,
    :tool_metadata,
    :max_retries,
    :llm_client,
    :hook_runner,
    :max_turns,
    :max_cost
  ]
  defstruct [
    :provider_pid,
    :request,
    :selection,
    :config,
    :tools,
    :project_root,
    :project_view,
    :fork_store,
    :tool_metadata,
    :changeset,
    :max_retries,
    :llm_client,
    :hook_runner,
    :max_turns,
    :max_cost,
    :session_pid,
    turn_count: 0,
    session_cost: 0.0
  ]

  @type t :: %__MODULE__{
          provider_pid: pid(),
          request: Request.t(),
          selection: ModelSelection.t(),
          config: MingaAgent.Config.t(),
          tools: [term()],
          project_root: String.t(),
          project_view: ProjectView.t() | nil,
          fork_store: pid() | nil,
          tool_metadata: map(),
          changeset: pid() | nil,
          max_retries: non_neg_integer(),
          llm_client: term(),
          hook_runner: MingaAgent.Providers.Native.hook_runner(),
          max_turns: pos_integer(),
          max_cost: float() | nil,
          session_pid: pid(),
          turn_count: non_neg_integer(),
          session_cost: float()
        }
end
