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
end
