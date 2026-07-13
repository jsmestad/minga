defmodule MingaEditor.State.Picker do
  @moduledoc """
  Groups picker-related fields from EditorState.

  Tracks the current picker instance, the source module providing candidates,
  the buffer index to restore on cancel, and the action-menu overlay state.
  """

  @typedoc "Action menu state: `{actions, selected_index}` or nil when closed."
  @type action_menu ::
          {[MingaEditor.UI.Picker.Source.action_entry()], non_neg_integer()} | nil

  @typedoc "Async loading status for sources that fetch candidates in the background."
  @type load_status :: :ready | :loading | {:error, String.t()}

  @typedoc """
  Latest-wins guard for async candidate fetches. Each `open_async` mints a fresh
  reference; a result whose revision doesn't match the live picker's is stale and
  dropped. A newer search, project switch, or reopen supersedes older in-flight
  fetches.
  """
  @type fetch_revision :: reference() | nil

  @type t :: %__MODULE__{
          picker: MingaEditor.UI.Picker.t() | nil,
          source: module() | nil,
          restore: non_neg_integer() | nil,
          restore_theme: MingaEditor.UI.Theme.t() | nil,
          action_menu: action_menu(),
          context: map() | nil,
          layout: MingaEditor.UI.Picker.Source.layout(),
          original_source: module() | nil,
          mode_prefix: String.t(),
          load_status: load_status(),
          fetch_revision: fetch_revision()
        }

  defstruct picker: nil,
            source: nil,
            restore: nil,
            restore_theme: nil,
            action_menu: nil,
            context: nil,
            layout: :bottom,
            original_source: nil,
            mode_prefix: "",
            load_status: :ready,
            fetch_revision: nil

  @doc "Returns true if a picker is currently open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{picker: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @doc "Returns a picker state with updated source context."
  @spec put_context(t(), map() | nil) :: t()
  def put_context(%__MODULE__{} = ps, context) do
    %{ps | context: context}
  end

  @doc "Updates the inner `MingaEditor.UI.Picker` instance."
  @spec update_picker(t(), MingaEditor.UI.Picker.t()) :: t()
  def update_picker(%__MODULE__{} = ps, picker) do
    %{ps | picker: picker}
  end

  @doc """
  Mints a fresh fetch revision and marks the picker as loading.

  Call this when starting an async candidate fetch. The returned `{ps, revision}`
  tuple lets the caller tag the off-path fetch with `revision` so a stale result
  (one whose revision no longer matches the live picker) can be dropped.
  """
  @spec begin_fetch(t()) :: {t(), reference()}
  def begin_fetch(%__MODULE__{} = ps) do
    revision = make_ref()
    {%{ps | fetch_revision: revision, load_status: :loading}, revision}
  end

  @doc "Returns whether `revision` is the picker's current (live) fetch revision."
  @spec current_fetch?(t(), fetch_revision()) :: boolean()
  def current_fetch?(%__MODULE__{fetch_revision: revision}, revision), do: true
  def current_fetch?(%__MODULE__{}, _revision), do: false
end
