defmodule Minga.Editing.Completion.Session do
  @moduledoc """
  Pure lifecycle authority for one completion interaction.

  Every request, batch, selection, and resolve operation carries the stable session, provider, and item identity needed to reject late work after supersession or teardown.
  """

  alias Minga.Editing.Completion.Item
  alias Minga.Editing.Completion.Index
  alias Minga.Editing.Completion.ProviderBatch

  @typedoc "Provider request identity and cancellation target."
  @type provider_request :: {client :: pid(), request_ref :: reference()}

  @typedoc "Stable resolve identity for one selected item."
  @type resolve_identity :: {reference(), Item.provider_id(), Item.id()}

  @typedoc "Whether ranking or explicit user navigation owns the current selection."
  @type selection_origin :: :automatic | :user

  @typedoc "Resolve work owned by this session."
  @type resolve :: %{
          identity: resolve_identity(),
          client: pid(),
          timer: reference() | nil,
          request_ref: reference() | nil
        }

  @enforce_keys [:id, :generation, :buffer, :buffer_version, :trigger_position]
  defstruct id: nil,
            generation: 0,
            buffer: nil,
            buffer_version: 0,
            trigger_position: {0, 0},
            provider_order: [],
            provider_requests: %{},
            batches: %{},
            index: %Index{},
            selected_item_id: nil,
            selection_origin: :automatic,
            previewed_item_id: nil,
            resolve: nil,
            debounce_timer: nil,
            dismissed?: false

  @type t :: %__MODULE__{
          id: reference(),
          generation: non_neg_integer(),
          buffer: pid(),
          buffer_version: non_neg_integer(),
          trigger_position: {non_neg_integer(), non_neg_integer()},
          provider_order: [Item.provider_id()],
          provider_requests: %{Item.provider_id() => provider_request()},
          batches: %{Item.provider_id() => ProviderBatch.t()},
          index: Index.t(),
          selected_item_id: Item.id() | nil,
          selection_origin: selection_origin(),
          previewed_item_id: Item.id() | nil,
          resolve: resolve() | nil,
          debounce_timer: reference() | nil,
          dismissed?: boolean()
        }

  @doc "Creates a completion session around one exact buffer snapshot."
  @spec new(
          reference(),
          non_neg_integer(),
          pid(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()}
        ) :: t()
  def new(id, generation, buffer, buffer_version, trigger_position)
      when is_reference(id) and is_integer(generation) and generation >= 0 and is_pid(buffer) and
             is_integer(buffer_version) and buffer_version >= 0 do
    %__MODULE__{
      id: id,
      generation: generation,
      buffer: buffer,
      buffer_version: buffer_version,
      trigger_position: trigger_position
    }
  end

  @doc "Installs the debounce timer owned by this session."
  @spec put_debounce_timer(t(), reference() | nil) :: t()
  def put_debounce_timer(%__MODULE__{} = session, timer)
      when is_reference(timer) or is_nil(timer),
      do: %{session | debounce_timer: timer}

  @doc "Moves a debounced session into provider-request ownership."
  @spec activate(t(), {non_neg_integer(), non_neg_integer()}) :: t()
  def activate(%__MODULE__{} = session, trigger_position) do
    %{session | trigger_position: trigger_position, debounce_timer: nil}
  end

  @doc "Registers one independently cancellable request per provider."
  @spec register_requests(t(), [{Item.provider_id(), pid(), reference()}]) :: t()
  def register_requests(%__MODULE__{} = session, requests) when is_list(requests) do
    provider_order =
      Enum.uniq(
        session.provider_order ++ Enum.map(requests, fn {provider_id, _, _} -> provider_id end)
      )

    provider_requests =
      Enum.reduce(requests, session.provider_requests, fn {provider_id, client, ref}, acc ->
        Map.put(acc, provider_id, {client, ref})
      end)

    %{
      session
      | provider_order: provider_order,
        provider_requests: provider_requests,
        debounce_timer: nil
    }
  end

  @doc "Advances an existing session for trigger-kind-3 requests while retaining complete batches."
  @spec retrigger(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          [{Item.provider_id(), pid(), reference()}]
        ) :: t()
  def retrigger(%__MODULE__{} = session, generation, buffer_version, requests)
      when is_integer(generation) and generation > session.generation and
             is_integer(buffer_version) and buffer_version >= session.buffer_version and
             is_list(requests) do
    session
    |> Map.put(:generation, generation)
    |> Map.put(:buffer_version, buffer_version)
    |> Map.put(:provider_requests, %{})
    |> register_requests(requests)
  end

  @doc "Advances the session snapshot after local filtering sends no provider request."
  @spec continue_locally(t(), non_neg_integer()) :: t()
  def continue_locally(%__MODULE__{} = session, buffer_version)
      when is_integer(buffer_version) and buffer_version >= session.buffer_version,
      do: %{session | buffer_version: buffer_version}

  @doc "Returns incomplete providers that require an LSP trigger-kind-3 refresh."
  @spec incomplete_providers(t()) :: [{Item.provider_id(), pid()}]
  def incomplete_providers(%__MODULE__{} = session) do
    Enum.flat_map(session.provider_order, fn provider_id ->
      case Map.fetch(session.batches, provider_id) do
        {:ok, %ProviderBatch{incomplete: true, client: client}} -> [{provider_id, client}]
        _ -> []
      end
    end)
  end

  @doc "Returns providers whose incomplete batch or pending request must refresh after input."
  @spec retrigger_providers(t()) :: [{Item.provider_id(), pid()}]
  def retrigger_providers(%__MODULE__{} = session) do
    Enum.flat_map(session.provider_order, &retrigger_provider(session, &1))
  end

  @doc "Accepts a batch only when it exactly matches the live provider request identity."
  @spec accept_batch(t(), ProviderBatch.t()) :: {:ok, t()} | :stale
  def accept_batch(%__MODULE__{dismissed?: false} = session, %ProviderBatch{} = batch) do
    expected = Map.get(session.provider_requests, batch.provider_id)

    if batch.session_id == session.id and batch.generation == session.generation and
         expected == {batch.client, batch.request_ref} do
      provider_requests = Map.delete(session.provider_requests, batch.provider_id)
      batches = Map.put(session.batches, batch.provider_id, batch)
      index = Index.put_provider(session.index, batch.provider_id, batch.items, batch.incomplete)
      next = %{session | provider_requests: provider_requests, batches: batches, index: index}
      {:ok, preserve_selection(next)}
    else
      :stale
    end
  end

  def accept_batch(%__MODULE__{}, %ProviderBatch{}), do: :stale

  @doc "Clears one failed provider request only when its request identity is still current."
  @spec fail_request(t(), Item.provider_id(), reference()) :: {:ok, t()} | :stale
  def fail_request(%__MODULE__{} = session, provider_id, request_ref) do
    case Map.fetch(session.provider_requests, provider_id) do
      {:ok, {_client, ^request_ref}} ->
        {:ok, %{session | provider_requests: Map.delete(session.provider_requests, provider_id)}}

      _ ->
        :stale
    end
  end

  @doc "Returns every candidate in deterministic provider and sort order."
  @spec items(t()) :: [Item.t()]
  def items(%__MODULE__{} = session), do: Index.all_items(session.index)

  @doc "Returns the provider-aware normalized index owned by this session."
  @spec index(t()) :: Index.t()
  def index(%__MODULE__{index: index}), do: index

  @doc "Records an explicit user selection by stable identity. Unknown or stale identities are ignored."
  @spec select(t(), Item.id() | nil) :: t()
  def select(%__MODULE__{} = session, nil),
    do: %{session | selected_item_id: nil, selection_origin: :automatic}

  def select(%__MODULE__{} = session, item_id) do
    if Index.find_item(session.index, item_id) != nil,
      do: %{session | selected_item_id: item_id, selection_origin: :user},
      else: session
  end

  @doc "Marks a locally previewed item so teardown can clear that ownership explicitly."
  @spec preview(t(), Item.id() | nil) :: t()
  def preview(%__MODULE__{} = session, item_id), do: %{session | previewed_item_id: item_id}

  @doc "Starts debounced resolve work for the current stable item identity."
  @spec begin_resolve(t(), Item.id(), pid(), reference() | nil) :: {:ok, t()} | :stale
  def begin_resolve(%__MODULE__{} = session, item_id, client, timer)
      when is_pid(client) and (is_reference(timer) or is_nil(timer)) do
    case find_item(session, item_id) do
      %Item{provider_id: provider_id} when session.selected_item_id == item_id ->
        resolve = %{
          identity: {session.id, provider_id, item_id},
          client: client,
          timer: timer,
          request_ref: nil
        }

        {:ok, %{session | resolve: resolve}}

      _ ->
        :stale
    end
  end

  @doc "Records the independently cancellable request ref for the active resolve."
  @spec track_resolve(t(), resolve_identity(), reference()) :: {:ok, t()} | :stale
  def track_resolve(
        %__MODULE__{resolve: %{identity: identity} = resolve} = session,
        identity,
        ref
      )
      when is_reference(ref),
      do: {:ok, %{session | resolve: %{resolve | timer: nil, request_ref: ref}}}

  def track_resolve(%__MODULE__{}, _identity, _ref), do: :stale

  @doc "Clears resolve ownership and returns its cancellation target and timer."
  @spec clear_resolve(t()) :: {t(), provider_request() | nil, reference() | nil}
  def clear_resolve(%__MODULE__{resolve: nil} = session), do: {session, nil, nil}

  def clear_resolve(%__MODULE__{resolve: resolve} = session) do
    request =
      case resolve do
        %{client: client, request_ref: ref} when is_reference(ref) -> {client, ref}
        _ -> nil
      end

    timer =
      case resolve do
        %{timer: timer} when is_reference(timer) -> timer
        _ -> nil
      end

    {%{session | resolve: nil}, request, timer}
  end

  @doc "Returns whether an exact resolve identity and request ref remain active."
  @spec resolve_current?(t(), resolve_identity(), reference()) :: boolean()
  def resolve_current?(
        %__MODULE__{dismissed?: false, resolve: %{identity: identity, request_ref: ref}},
        identity,
        ref
      ),
      do: true

  def resolve_current?(%__MODULE__{}, _identity, _ref), do: false

  @doc "Clears a failed resolve only when its stable identity and request ref are current."
  @spec fail_resolve(t(), resolve_identity(), reference()) :: {:ok, t()} | :stale
  def fail_resolve(%__MODULE__{} = session, identity, request_ref) do
    if resolve_current?(session, identity, request_ref),
      do: {:ok, %{session | resolve: nil}},
      else: :stale
  end

  @doc "Applies resolved documentation only to the exact live resolve identity and request."
  @spec resolve_item(t(), resolve_identity(), reference(), String.t()) :: {:ok, t()} | :stale
  def resolve_item(
        %__MODULE__{resolve: %{identity: identity, request_ref: ref}} = session,
        identity,
        ref,
        documentation
      )
      when is_binary(documentation) do
    {_session_id, provider_id, item_id} = identity

    case Map.fetch(session.batches, provider_id) do
      {:ok, batch} ->
        items = Enum.map(batch.items, &resolve_matching_item(&1, item_id, documentation))
        batches = Map.put(session.batches, provider_id, %{batch | items: items})
        index = Index.update_item(session.index, item_id, &Item.resolve(&1, documentation))
        {:ok, %{session | batches: batches, index: index, resolve: nil}}

      :error ->
        :stale
    end
  end

  def resolve_item(%__MODULE__{}, _identity, _ref, _documentation), do: :stale

  @doc "Returns cancellation targets and timers while clearing every owned lifecycle value."
  @spec teardown(t()) :: {t(), [provider_request()], [reference()]}
  def teardown(%__MODULE__{} = session) do
    requests = Map.values(session.provider_requests) ++ resolve_request(session.resolve)
    timers = timer_list(session.debounce_timer) ++ resolve_timer(session.resolve)

    {%{
       session
       | provider_requests: %{},
         batches: %{},
         index: Index.empty(),
         selected_item_id: nil,
         selection_origin: :automatic,
         previewed_item_id: nil,
         resolve: nil,
         debounce_timer: nil,
         dismissed?: true
     }, requests, timers}
  end

  @doc "Returns whether a response still belongs to this exact session and buffer snapshot."
  @spec current?(t(), reference(), non_neg_integer(), pid(), non_neg_integer()) :: boolean()
  def current?(session, id, generation, buffer, version) do
    session.dismissed? == false and session.id == id and session.generation == generation and
      session.buffer == buffer and session.buffer_version == version
  end

  @doc "Finds one item by stable identity."
  @spec find_item(t(), Item.id()) :: Item.t() | nil
  def find_item(%__MODULE__{} = session, item_id),
    do: Index.find_item(session.index, item_id)

  @spec preserve_selection(t()) :: t()
  defp preserve_selection(%__MODULE__{selection_origin: :user} = session) do
    case Index.find_item(session.index, session.selected_item_id) do
      %Item{} ->
        session

      nil ->
        select_automatic_default(session)
    end
  end

  defp preserve_selection(%__MODULE__{selection_origin: :automatic} = session),
    do: select_automatic_default(session)

  @spec select_automatic_default(t()) :: t()
  defp select_automatic_default(%__MODULE__{} = session) do
    first = session.index |> Index.snapshot("", 1) |> Map.fetch!(:items) |> first_item_id()
    %{session | selected_item_id: first, selection_origin: :automatic}
  end

  @spec first_item_id([Item.t()]) :: Item.id() | nil
  defp first_item_id([%Item{id: id} | _]), do: id
  defp first_item_id([]), do: nil

  @spec resolve_matching_item(Item.t(), Item.id(), String.t()) :: Item.t()
  defp resolve_matching_item(%Item{id: item_id} = item, item_id, documentation),
    do: Item.resolve(item, documentation)

  defp resolve_matching_item(%Item{} = item, _item_id, _documentation), do: item

  @spec retrigger_provider(t(), Item.provider_id()) :: [{Item.provider_id(), pid()}]
  defp retrigger_provider(%__MODULE__{} = session, provider_id) do
    case {Map.get(session.provider_requests, provider_id), Map.get(session.batches, provider_id)} do
      {{client, _request_ref}, _batch} -> [{provider_id, client}]
      {nil, %ProviderBatch{incomplete: true, client: client}} -> [{provider_id, client}]
      _ -> []
    end
  end

  @spec resolve_request(resolve() | nil) :: [provider_request()]
  defp resolve_request(%{client: client, request_ref: ref}) when is_reference(ref),
    do: [{client, ref}]

  defp resolve_request(_resolve), do: []

  @spec timer_list(reference() | nil) :: [reference()]
  defp timer_list(timer) when is_reference(timer), do: [timer]
  defp timer_list(_timer), do: []

  @spec resolve_timer(resolve() | nil) :: [reference()]
  defp resolve_timer(%{timer: timer}), do: timer_list(timer)
  defp resolve_timer(_resolve), do: []
end
