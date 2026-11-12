defmodule MingaAgent.Session.PrefixStore do
  @moduledoc "Pure, content-addressed instruction/schema interning and replay epoch ownership."

  alias MingaAgent.Session.Prefix

  defstruct instructions: %{}, schemas: %{}, prefixes: %{}, epochs: %{}, selected: :unknown

  @type epoch_ref :: String.t() | :unknown
  @type t :: %__MODULE__{
          instructions: %{String.t() => String.t()},
          schemas: %{String.t() => [map()]},
          prefixes: %{String.t() => {String.t(), String.t(), [String.t()]}},
          epochs: %{String.t() => {String.t(), map()}},
          selected: epoch_ref()
        }

  @doc "Creates an empty store with explicitly unknown historical evidence."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Builds a stable candidate without retaining it or any executable value."
  @spec candidate(String.t(), [map()], map()) :: {:ok, Prefix.t()} | {:error, term()}
  def candidate(instructions, schemas, identity),
    do: candidate(:unknown, instructions, schemas, identity, [])

  @doc "Reuses component identities when a candidate retains the previous immutable values."
  @spec candidate(Prefix.t() | :unknown, String.t(), [map()], map()) ::
          {:ok, Prefix.t()} | {:error, term()}
  def candidate(previous, instructions, schemas, identity) do
    skills =
      case previous do
        %Prefix{skills: skills} -> skills
        :unknown -> []
      end

    candidate(previous, instructions, schemas, identity, skills)
  end

  @doc "Captures the selected skill names alongside their immutable instruction value."
  @spec candidate(Prefix.t() | :unknown, String.t(), [map()], map(), [String.t()]) ::
          {:ok, Prefix.t()} | {:error, term()}
  def candidate(
        %Prefix{instructions: instructions, schemas: schemas, identity: identity, skills: skills} =
          previous,
        instructions,
        schemas,
        identity,
        skills
      ),
      do: {:ok, previous}

  def candidate(%Prefix{schemas: schemas} = previous, instructions, schemas, identity, skills)
      when is_binary(instructions) and is_map(identity) do
    if valid_identity?(identity) and valid_skills?(skills),
      do: build_candidate(previous, instructions, schemas, identity, skills),
      else: {:error, :invalid_prefix_candidate}
  end

  def candidate(previous, instructions, schemas, identity, skills)
      when is_binary(instructions) and is_list(schemas) and is_map(identity) do
    with true <- Enum.all?(schemas, &valid_schema?/1),
         true <- valid_identity?(identity),
         true <- valid_skills?(skills),
         schemas = Enum.sort_by(schemas, & &1.name),
         names = Enum.map(schemas, & &1.name),
         true <- length(Enum.uniq(names)) == length(names),
         true <- data?(schemas) do
      build_candidate(previous, instructions, schemas, identity, skills)
    else
      false -> {:error, :invalid_prefix_candidate}
    end
  end

  @spec build_candidate(Prefix.t() | :unknown, String.t(), [map()], map(), [String.t()]) ::
          {:ok, Prefix.t()}
  defp build_candidate(previous, instructions, schemas, identity, skills) do
    instructions_id = component_identity(previous, :instructions, instructions)
    schemas_id = component_identity(previous, :schemas, schemas)
    prefix_id = digest(:prefix, {instructions_id, schemas_id, skills})
    epoch_id = digest(:epoch, {prefix_id, identity})

    {:ok,
     Prefix.new(
       epoch_id,
       prefix_id,
       instructions_id,
       schemas_id,
       instructions,
       schemas,
       identity,
       skills
     )}
  end

  @doc "Selects and interns a candidate, sharing instructions and schemas independently."
  @spec select(t(), Prefix.t()) :: t()
  def select(%__MODULE__{selected: id} = store, %Prefix{epoch_id: id}), do: store

  def select(%__MODULE__{} = store, %Prefix{} = prefix) do
    instructions_id = prefix.instructions_id
    schemas_id = prefix.schemas_id

    %{
      store
      | instructions: Map.put_new(store.instructions, instructions_id, prefix.instructions),
        schemas: Map.put_new(store.schemas, schemas_id, prefix.schemas),
        prefixes:
          Map.put_new(
            store.prefixes,
            prefix.prefix_id,
            {instructions_id, schemas_id, prefix.skills}
          ),
        epochs: Map.put_new(store.epochs, prefix.epoch_id, {prefix.prefix_id, prefix.identity}),
        selected: prefix.epoch_id
    }
  end

  @doc "Selects a retained branch epoch without substituting current inputs."
  @spec select_epoch(t(), epoch_ref()) :: t()
  def select_epoch(%__MODULE__{} = store, :unknown), do: %{store | selected: :unknown}

  def select_epoch(%__MODULE__{epochs: epochs} = store, id) when is_map_key(epochs, id),
    do: %{store | selected: id}

  @doc "Resolves one reference to shared immutable values."
  @spec resolve(t(), epoch_ref()) :: Prefix.t() | :unknown
  def resolve(%__MODULE__{}, :unknown), do: :unknown

  def resolve(%__MODULE__{} = store, epoch_id) do
    {prefix_id, identity} = Map.fetch!(store.epochs, epoch_id)
    {instructions_id, schemas_id, skills} = Map.fetch!(store.prefixes, prefix_id)

    Prefix.new(
      epoch_id,
      prefix_id,
      instructions_id,
      schemas_id,
      Map.fetch!(store.instructions, instructions_id),
      Map.fetch!(store.schemas, schemas_id),
      identity,
      skills
    )
  end

  @doc "Removes values unreachable from selected history, branches, or active work."
  @spec retain(t(), [epoch_ref()]) :: t()
  def retain(%__MODULE__{} = store, roots) do
    epochs = Map.take(store.epochs, [store.selected | roots])

    prefixes =
      Map.take(store.prefixes, Enum.map(epochs, fn {_id, {prefix_id, _}} -> prefix_id end))

    instruction_ids = Enum.map(prefixes, fn {_id, {instructions_id, _, _}} -> instructions_id end)
    schema_ids = Enum.map(prefixes, fn {_id, {_, schemas_id, _}} -> schemas_id end)

    %{
      store
      | epochs: epochs,
        prefixes: prefixes,
        instructions: Map.take(store.instructions, instruction_ids),
        schemas: Map.take(store.schemas, schema_ids)
    }
  end

  @doc "Returns a codec value containing each interned component exactly once."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = store), do: Map.put(Map.from_struct(store), :version, 1)

  @doc "Validates all digests and references before accepting current-format storage."
  @spec restore(term()) :: {:ok, t()} | {:error, :invalid_prefix_store}
  def restore(
        %{
          version: 1,
          instructions: instructions,
          schemas: schemas,
          prefixes: prefixes,
          epochs: epochs,
          selected: selected
        } = data
      )
      when map_size(data) == 6 and is_map(instructions) and is_map(schemas) and
             is_map(prefixes) and is_map(epochs) do
    store = struct!(__MODULE__, Map.delete(data, :version))

    if valid_components?(instructions, :instructions) and valid_components?(schemas, :schemas) and
         valid_prefixes?(store) and valid_epochs?(store) and known?(store, selected) do
      {:ok, store}
    else
      {:error, :invalid_prefix_store}
    end
  rescue
    ArgumentError -> {:error, :invalid_prefix_store}
  end

  def restore(_data), do: {:error, :invalid_prefix_store}

  @doc "Returns whether a reference is retained or explicitly unknown."
  @spec known?(t(), epoch_ref()) :: boolean()
  def known?(%__MODULE__{}, :unknown), do: true
  def known?(%__MODULE__{epochs: epochs}, id), do: is_binary(id) and Map.has_key?(epochs, id)

  @spec digest(atom(), term()) :: String.t()
  defp digest(kind, value) do
    encoded = :erlang.term_to_binary({1, kind, value}, [:deterministic])
    "px1_" <> Base.url_encode64(:crypto.hash(:sha256, encoded), padding: false)
  end

  @spec component_identity(Prefix.t() | :unknown, :instructions | :schemas, term()) :: String.t()
  defp component_identity(
         %Prefix{instructions: value, instructions_id: id},
         :instructions,
         value
       ),
       do: id

  defp component_identity(%Prefix{schemas: value, schemas_id: id}, :schemas, value), do: id
  defp component_identity(_previous, kind, value), do: digest(kind, value)

  @spec valid_components?(map(), atom()) :: boolean()
  defp valid_components?(components, kind) do
    Enum.all?(components, fn {id, value} ->
      data?(value) and id == digest(kind, value) and valid_component?(kind, value)
    end)
  end

  @spec valid_component?(atom(), term()) :: boolean()
  defp valid_component?(:instructions, value), do: is_binary(value)

  defp valid_component?(:schemas, value) when is_list(value) do
    Enum.all?(value, &valid_schema?/1) and ordered_schema_names?(value)
  end

  defp valid_component?(_kind, _value), do: false

  @spec valid_prefixes?(t()) :: boolean()
  defp valid_prefixes?(store) do
    Enum.all?(store.prefixes, fn
      {id, {instructions_id, schemas_id, skills} = value} ->
        valid_skills?(skills) and id == digest(:prefix, value) and
          Map.has_key?(store.instructions, instructions_id) and
          Map.has_key?(store.schemas, schemas_id)

      _invalid ->
        false
    end)
  end

  @spec valid_epochs?(t()) :: boolean()
  defp valid_epochs?(store) do
    Enum.all?(store.epochs, fn
      {id, {prefix_id, identity} = value} when is_map(identity) ->
        valid_identity?(identity) and id == digest(:epoch, value) and
          Map.has_key?(store.prefixes, prefix_id)

      _invalid ->
        false
    end)
  end

  @spec valid_skills?(term()) :: boolean()
  defp valid_skills?(skills) when is_list(skills),
    do:
      Enum.all?(skills, &(is_binary(&1) and &1 != "")) and
        length(skills) == length(Enum.uniq(skills))

  defp valid_skills?(_invalid), do: false

  @spec ordered_schema_names?([map()]) :: boolean()
  defp ordered_schema_names?(schemas) do
    names = Enum.map(schemas, & &1.name)
    names == Enum.sort(Enum.uniq(names))
  end

  @spec valid_schema?(term()) :: boolean()
  defp valid_schema?(
         %{
           name: name,
           description: description,
           parameter_schema: parameters,
           strict: strict,
           provider_options: options,
           source: source
         } = schema
       )
       when map_size(schema) == 6 and is_binary(name) and name != "" and is_binary(description) and
              is_map(parameters) and is_boolean(strict) and (is_map(options) or is_list(options)) do
    data?(schema) and valid_source?(source)
  end

  defp valid_schema?(_schema), do: false

  @spec valid_source?(term()) :: boolean()
  defp valid_source?(source) when source in [:builtin, :config], do: true

  defp valid_source?({tag, owner}) when tag in [:bundle, :extension, :local] and is_binary(owner),
    do: owner != ""

  defp valid_source?(_source), do: false

  @spec valid_identity?(term()) :: boolean()
  defp valid_identity?(
         %{
           selection_id: "ms2_" <> digest,
           authentication: authentication,
           native_contract: contract
         } = identity
       )
       when map_size(identity) == 3 and byte_size(digest) == 43 and
              contract in [:unknown, :codex_responses_exact_prefix_v1] do
    valid_url_identity?(digest, 32) and valid_authentication?(authentication)
  end

  defp valid_identity?(%{native_contract: :provider_owned, provider: provider} = identity)
       when map_size(identity) == 2 and is_atom(provider) and provider not in [nil, true, false],
       do: true

  defp valid_identity?(_identity), do: false

  @spec valid_authentication?(term()) :: boolean()
  defp valid_authentication?(%{kind: :api_key, runtime_binding: binding} = authentication)
       when map_size(authentication) == 2 and is_binary(binding) and byte_size(binding) == 32,
       do: valid_url_identity?(binding, 24)

  defp valid_authentication?(
         %{kind: :oauth, account_id: account, source_id: source} = authentication
       )
       when map_size(authentication) == 3 and is_binary(account) and account != "" and
              is_binary(source) and byte_size(source) == 64,
       do: match?({:ok, _}, Base.decode16(source, case: :lower))

  defp valid_authentication?(_authentication), do: false

  @spec valid_url_identity?(String.t(), pos_integer()) :: boolean()
  defp valid_url_identity?(value, bytes) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} ->
        byte_size(decoded) == bytes and Base.url_encode64(decoded, padding: false) == value

      :error ->
        false
    end
  end

  @spec data?(term()) :: boolean()
  defp data?(value) when is_binary(value) or is_atom(value) or is_number(value), do: true
  defp data?(value) when is_list(value), do: Enum.all?(value, &data?/1)
  defp data?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.all?(&data?/1)
  defp data?(%{__struct__: _}), do: false

  defp data?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> data?(key) and data?(item) end)

  defp data?(_value), do: false
end
