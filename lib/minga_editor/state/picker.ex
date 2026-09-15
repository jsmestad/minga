defmodule MingaEditor.State.Picker do
  @moduledoc """
  Groups picker-related fields from EditorState.

  Tracks the current picker instance, the source module providing candidates,
  the buffer index to restore on cancel, and the action-menu overlay state.
  """

  alias MingaEditor.State.Picker.ActivationOffer

  @typedoc "Action menu state: `{actions, selected_index, captured_item}` or nil when closed."
  @type action_menu ::
          {[MingaEditor.UI.Picker.Source.action_entry()], non_neg_integer(),
           MingaEditor.UI.Picker.Item.t()}
          | nil

  @type action_menu_direction :: :next | :previous

  @typedoc "Async loading status for sources that fetch candidates in the background."
  @type load_status :: :ready | :loading | {:error, String.t()}

  @typedoc "Contribution source semantically authorized to provide picker candidates."
  @type callback_source :: Minga.Extension.ContributionCleanup.contribution_source() | nil

  @typedoc "Source-switch state for the picker currently shown."
  @type source_switch :: :original | {:switched, module(), String.t()}
  @type source_transition :: {:switch, String.t()} | :restore

  @typedoc "Source metadata installed by a picker source transition."
  @type source_target ::
          {module(), callback_source(), MingaEditor.UI.Picker.Source.layout()}

  @typedoc "Correlation generation for native full-query editing."
  @type query_generation :: non_neg_integer()

  @typedoc "Latest native query edit accepted by the BEAM."
  @type query_edit_seq :: non_neg_integer()

  @typedoc """
  Latest-wins guard for async candidate fetches. Each `open_async` mints a fresh
  reference; a result whose revision doesn't match the live picker's is stale and
  dropped. A newer search, project switch, or reopen supersedes older in-flight
  fetches.
  """
  @type fetch_revision :: reference() | nil
  @type fetch_identity :: term() | nil

  @type t :: %__MODULE__{
          picker: MingaEditor.UI.Picker.t() | nil,
          source: module() | nil,
          callback_source: callback_source(),
          restore: non_neg_integer() | nil,
          restore_theme: MingaEditor.UI.Theme.t() | nil,
          action_menu: action_menu(),
          context: map() | nil,
          layout: MingaEditor.UI.Picker.Source.layout(),
          source_switch: source_switch(),
          load_status: load_status(),
          fetch_revision: fetch_revision(),
          fetch_identity: fetch_identity(),
          query_generation: query_generation(),
          acknowledged_query_edit_seq: query_edit_seq(),
          activation_offer: ActivationOffer.t()
        }

  defstruct picker: nil,
            source: nil,
            callback_source: nil,
            restore: nil,
            restore_theme: nil,
            action_menu: nil,
            context: nil,
            layout: :bottom,
            source_switch: :original,
            load_status: :ready,
            fetch_revision: nil,
            fetch_identity: nil,
            query_generation: 0,
            acknowledged_query_edit_seq: 0,
            activation_offer: %ActivationOffer{generation: 1}

  @doc "Builds the semantic state for an asynchronous picker before fetching starts."
  @spec loading(
          MingaEditor.UI.Picker.t(),
          module(),
          callback_source(),
          non_neg_integer() | nil,
          MingaEditor.UI.Theme.t() | nil,
          map() | nil,
          MingaEditor.UI.Picker.Source.layout()
        ) :: t()
  def loading(picker, source, callback_source, restore, restore_theme, context, layout)
      when is_atom(source) do
    %__MODULE__{
      picker: picker,
      source: source,
      callback_source: callback_source,
      restore: restore,
      restore_theme: restore_theme,
      context: context,
      layout: layout,
      load_status: :loading
    }
    |> begin_query_session()
  end

  @doc "Starts a fresh native query-editing generation."
  @spec begin_query_session(t()) :: t()
  def begin_query_session(%__MODULE__{} = ps) do
    generation = Integer.mod(System.unique_integer([:positive, :monotonic]), 4_294_967_295) + 1

    %{ps | query_generation: generation, acknowledged_query_edit_seq: 0}
    |> refresh_activation_offer()
  end

  @doc "Returns whether a native query edit belongs to this picker and is newer than its acknowledgement."
  @spec current_query_edit?(t(), query_generation(), query_edit_seq()) :: boolean()
  def current_query_edit?(
        %__MODULE__{
          query_generation: generation,
          acknowledged_query_edit_seq: acknowledged_edit_seq
        },
        generation,
        edit_seq
      )
      when edit_seq > acknowledged_edit_seq,
      do: true

  def current_query_edit?(%__MODULE__{}, _generation, _edit_seq), do: false

  @doc "Installs an accepted native query and advances its acknowledgement."
  @spec accept_query_edit(t(), MingaEditor.UI.Picker.t(), query_edit_seq()) :: t()
  def accept_query_edit(
        %__MODULE__{acknowledged_query_edit_seq: acknowledged_edit_seq} = ps,
        picker,
        edit_seq
      )
      when edit_seq > acknowledged_edit_seq do
    %{ps | picker: picker, acknowledged_query_edit_seq: edit_seq}
    |> refresh_activation_offer()
  end

  def accept_query_edit(%__MODULE__{} = ps, _picker, _edit_seq), do: ps

  @doc "Returns true if a picker is currently open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{picker: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @doc "Returns whether this picker is semantically owned by a contribution source."
  @spec owned_by?(t(), callback_source()) :: boolean()
  def owned_by?(%__MODULE__{callback_source: nil}, _source), do: false
  def owned_by?(%__MODULE__{callback_source: source}, source), do: true
  def owned_by?(%__MODULE__{}, _source), do: false

  @doc "Returns a picker state with updated source context."
  @spec put_context(t(), map() | nil) :: t()
  def put_context(%__MODULE__{} = ps, context) do
    %{ps | context: context}
  end

  @doc "Updates the inner `MingaEditor.UI.Picker` instance."
  @spec update_picker(t(), MingaEditor.UI.Picker.t()) :: t()
  def update_picker(%__MODULE__{} = ps, picker) do
    %{ps | picker: picker}
    |> refresh_activation_offer()
  end

  @doc "Opens the source action menu for the exact item or marked set captured by `actions`."
  @spec open_action_menu(
          t(),
          [MingaEditor.UI.Picker.Source.action_entry()],
          MingaEditor.UI.Picker.Item.t()
        ) :: t()
  def open_action_menu(%__MODULE__{} = ps, [_first | _rest] = actions, item) do
    %{ps | action_menu: {actions, 0, item}}
    |> refresh_activation_offer()
  end

  def open_action_menu(%__MODULE__{} = ps, [], _item), do: ps

  @doc "Moves the action-menu selection when the menu is open."
  @spec move_action_menu_selection(t(), action_menu_direction()) :: t()
  def move_action_menu_selection(
        %__MODULE__{action_menu: {[], _selected, _item}} = ps,
        _direction
      ),
      do: ps

  def move_action_menu_selection(
        %__MODULE__{action_menu: {[_first | _rest] = actions, selected, item}} = ps,
        :next
      ) do
    next_selected = rem(selected + 1, length(actions))

    %{ps | action_menu: {actions, next_selected, item}}
    |> refresh_activation_offer()
  end

  def move_action_menu_selection(
        %__MODULE__{action_menu: {[_first | _rest] = actions, selected, item}} = ps,
        :previous
      ) do
    previous_selected = if selected == 0, do: length(actions) - 1, else: selected - 1

    %{ps | action_menu: {actions, previous_selected, item}}
    |> refresh_activation_offer()
  end

  def move_action_menu_selection(%__MODULE__{action_menu: nil} = ps, _direction), do: ps

  @doc "Closes the source action menu if it is open."
  @spec close_action_menu(t()) :: t()
  def close_action_menu(%__MODULE__{action_menu: nil} = ps), do: ps

  def close_action_menu(%__MODULE__{} = ps) do
    %{ps | action_menu: nil}
    |> refresh_activation_offer()
  end

  @doc "Replaces the activation offer after any result or action-menu transition."
  @spec refresh_activation_offer(t()) :: t()
  def refresh_activation_offer(%__MODULE__{picker: picker, action_menu: action_menu} = ps) do
    %{ps | activation_offer: ActivationOffer.new(picker, action_menu)}
  end

  @doc "Resolves an exact item identity from the current activation offer."
  @spec resolve_item_activation(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer(), MingaEditor.UI.Picker.Item.t()} | :error
  def resolve_item_activation(%__MODULE__{activation_offer: offer}, generation, activation_id) do
    ActivationOffer.resolve_item(offer, generation, activation_id)
  end

  @doc "Resolves an exact action identity from the current activation offer."
  @spec resolve_action_activation(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, MingaEditor.UI.Picker.Source.action_entry(), MingaEditor.UI.Picker.Item.t()}
          | :error
  def resolve_action_activation(%__MODULE__{activation_offer: offer}, generation, activation_id) do
    ActivationOffer.resolve_action(offer, generation, activation_id)
  end

  @doc "Returns the visible prefix for a switched source."
  @spec mode_prefix(t()) :: String.t()
  def mode_prefix(%__MODULE__{source_switch: {:switched, _original_source, prefix}}), do: prefix
  def mode_prefix(%__MODULE__{}), do: ""

  @doc "Retargets an open picker while retaining its session-owned fields."
  @spec retarget(t(), MingaEditor.UI.Picker.t(), source_target(), source_transition()) :: t()
  def retarget(
        %__MODULE__{source: original_source, source_switch: :original} = ps,
        picker,
        target,
        {:switch, prefix}
      )
      when is_atom(original_source) and is_binary(prefix),
      do: put_source(ps, picker, target, {:switched, original_source, prefix})

  def retarget(
        %__MODULE__{source_switch: {:switched, original_source, _old_prefix}} = ps,
        picker,
        target,
        {:switch, prefix}
      )
      when is_binary(prefix),
      do: put_source(ps, picker, target, {:switched, original_source, prefix})

  def retarget(
        %__MODULE__{source_switch: {:switched, original_source, _prefix}} = ps,
        picker,
        {original_source, _callback_source, _layout} = target,
        :restore
      ),
      do: put_source(ps, picker, target, :original)

  @spec put_source(t(), MingaEditor.UI.Picker.t(), source_target(), source_switch()) :: t()
  defp put_source(ps, picker, {source, callback_source, layout}, source_switch) do
    %{
      ps
      | picker: picker,
        source: source,
        callback_source: callback_source,
        layout: layout,
        source_switch: source_switch,
        load_status: :ready,
        fetch_revision: nil,
        fetch_identity: nil
    }
    |> refresh_activation_offer()
  end

  @doc "Retargets an open picker and replaces its immutable source context atomically."
  @spec retarget_with_context(t(), MingaEditor.UI.Picker.t(), source_target(), term()) :: t()
  def retarget_with_context(%__MODULE__{} = ps, picker, target, context) do
    ps
    |> put_source(picker, target, ps.source_switch)
    |> put_context(context)
  end

  @doc """
  Mints a fresh fetch revision and marks the picker as loading.

  Call this when starting an async candidate fetch. The returned `{ps, revision}`
  tuple lets the caller tag the off-path fetch with `revision` so a stale result
  (one whose revision no longer matches the live picker) can be dropped.
  """
  @spec begin_fetch(t(), fetch_identity()) :: {t(), reference()}
  def begin_fetch(%__MODULE__{} = ps, identity \\ nil) do
    revision = make_ref()

    state =
      %{ps | fetch_revision: revision, fetch_identity: identity, load_status: :loading}
      |> refresh_activation_offer()

    {state, revision}
  end

  @doc "Accepts normalized candidates for the current asynchronous fetch."
  @spec complete_fetch(t(), MingaEditor.UI.Picker.t()) :: t()
  def complete_fetch(%__MODULE__{} = ps, picker) do
    %{ps | picker: picker, load_status: :ready}
    |> refresh_activation_offer()
  end

  @doc "Records a user-visible failure for the current asynchronous fetch."
  @spec fail_fetch(t(), String.t()) :: t()
  def fail_fetch(%__MODULE__{} = ps, reason) when is_binary(reason) do
    %{ps | load_status: {:error, reason}}
  end

  @doc "Invalidates any prior asynchronous result after a ready-state context-only edit."
  @spec invalidate_fetch(t()) :: t()
  def invalidate_fetch(%__MODULE__{} = ps) do
    %{ps | fetch_revision: nil, fetch_identity: nil}
  end

  @doc "Returns whether `revision` is the picker's current (live) fetch revision."
  @spec current_fetch?(t(), fetch_revision(), fetch_identity()) :: boolean()
  def current_fetch?(
        %__MODULE__{fetch_revision: revision, fetch_identity: identity},
        revision,
        identity
      )
      when is_reference(revision),
      do: true

  def current_fetch?(%__MODULE__{}, _revision, _identity), do: false

  @doc "Returns whether `revision` is current for a source without an additional identity."
  @spec current_fetch?(t(), fetch_revision()) :: boolean()
  def current_fetch?(%__MODULE__{} = ps, revision), do: current_fetch?(ps, revision, nil)
end
