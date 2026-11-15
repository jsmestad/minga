defmodule MingaAgent.Session.Prefix do
  @moduledoc "Resolved immutable instruction and schema values for one request epoch."

  @enforce_keys [
    :epoch_id,
    :prefix_id,
    :instructions_id,
    :schemas_id,
    :instructions,
    :schemas,
    :identity,
    :skills
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          epoch_id: String.t(),
          prefix_id: String.t(),
          instructions_id: String.t(),
          schemas_id: String.t(),
          instructions: String.t(),
          schemas: [map()],
          identity: map(),
          skills: [String.t()]
        }

  @doc "Constructs a resolved view from interned values."
  @spec new(String.t(), String.t(), String.t(), String.t(), String.t(), [map()], map(), [
          String.t()
        ]) :: t()
  def new(
        epoch_id,
        prefix_id,
        instructions_id,
        schemas_id,
        instructions,
        schemas,
        identity,
        skills
      ) do
    %__MODULE__{
      epoch_id: epoch_id,
      prefix_id: prefix_id,
      instructions_id: instructions_id,
      schemas_id: schemas_id,
      instructions: instructions,
      schemas: schemas,
      identity: identity,
      skills: skills
    }
  end

  @doc "Allows only qualification of fully captured, otherwise identical prefix evidence."
  @spec requalifies?(t(), t()) :: boolean()
  def requalifies?(
        %__MODULE__{
          prefix_id: prefix_id,
          instructions_id: instructions_id,
          schemas_id: schemas_id,
          instructions: instructions,
          schemas: schemas,
          skills: skills,
          identity: captured
        },
        %__MODULE__{
          prefix_id: prefix_id,
          instructions_id: instructions_id,
          schemas_id: schemas_id,
          instructions: instructions,
          schemas: schemas,
          skills: skills,
          identity: current
        }
      ),
      do: requalifies_replay_identity?(captured, current)

  def requalifies?(%__MODULE__{}, %__MODULE__{}), do: false

  @doc "Recognizes a classifier-only qualification of the exact captured selection and authentication."
  @spec requalifies_replay_identity?(map(), map()) :: boolean()
  def requalifies_replay_identity?(
        %{
          selection_id: selection_id,
          authentication: authentication,
          native_contract: :unknown
        } = captured,
        %{
          selection_id: selection_id,
          authentication: authentication,
          native_contract: :codex_responses_exact_prefix_v1
        } = current
      )
      when is_binary(selection_id) and is_map(authentication) and map_size(captured) == 3 and
             map_size(current) == 3,
      do: true

  def requalifies_replay_identity?(_captured, _current), do: false
end
