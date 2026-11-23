defmodule MingaAgent.Session.Prefix do
  @moduledoc """
  Resolved immutable instruction and schema values for one request epoch.

  `omitted` records the optional instruction parts a route's prefix budget left out of `instructions`, so the omission is part of the epoch's evidence and can be disclosed instead of being dropped silently.
  """

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
  defstruct @enforce_keys ++ [omitted: []]

  @typedoc "An optional instruction part that a route's prefix budget can leave out."
  @type omittable :: :instructions | :skills | :append_prompt

  @type t :: %__MODULE__{
          epoch_id: String.t(),
          prefix_id: String.t(),
          instructions_id: String.t(),
          schemas_id: String.t(),
          instructions: String.t(),
          schemas: [map()],
          identity: map(),
          skills: [String.t()],
          omitted: [omittable()]
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

  @doc "Records the optional parts a route's prefix budget left out of the instructions."
  @spec omitting(t(), [omittable()]) :: t()
  def omitting(%__MODULE__{} = prefix, omitted) when is_list(omitted),
    do: %{prefix | omitted: omitted}

  @doc "Lists the parts this prefix can omit, in the order a budget considers them."
  @spec omittable() :: [omittable(), ...]
  def omittable, do: [:instructions, :skills, :append_prompt]

  @doc "Describes the omitted parts for the transcript, or returns nil when nothing was omitted."
  @spec omission_notice(t(), String.t()) :: String.t() | nil
  def omission_notice(%__MODULE__{omitted: []}, _model_name), do: nil

  def omission_notice(%__MODULE__{omitted: omitted}, model_name) when is_binary(model_name) do
    parts = omitted |> Enum.map(&omitted_name/1) |> join_names()

    "#{model_name} is not sending #{parts}: they do not fit its context with room for the conversation. Choose a model with a larger context to use them."
  end

  @spec omitted_name(omittable()) :: String.t()
  defp omitted_name(:instructions), do: "the project instruction files"
  defp omitted_name(:skills), do: "the active skills"
  defp omitted_name(:append_prompt), do: "the append prompt"

  @spec join_names([String.t(), ...]) :: String.t()
  defp join_names([name]), do: name
  defp join_names([first, second]), do: "#{first} and #{second}"
  defp join_names([first, second, third]), do: "#{first}, #{second} and #{third}"

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
          omitted: omitted,
          identity: captured
        },
        %__MODULE__{
          prefix_id: prefix_id,
          instructions_id: instructions_id,
          schemas_id: schemas_id,
          instructions: instructions,
          schemas: schemas,
          skills: skills,
          omitted: omitted,
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
