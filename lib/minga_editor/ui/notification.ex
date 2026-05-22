defmodule MingaEditor.UI.Notification do
  @moduledoc """
  BEAM-owned model for structured editor notifications.

  Native GUI frontends render these as bottom-right notification cards. TUI users receive the same important information through `*Messages*` at the call site.
  """

  alias MingaEditor.UI.Notification.Action

  @type level :: :info | :warning | :error | :success | :progress

  @enforce_keys [:id, :level, :title, :created_at]
  defstruct [
    :id,
    :level,
    :title,
    :body,
    :source,
    :auto_dismiss_ms,
    :created_at,
    :updated_at,
    :dismiss_ref,
    actions: [],
    dismissable: true
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          level: level(),
          title: String.t(),
          body: String.t() | nil,
          source: String.t() | nil,
          actions: [Action.t()],
          dismissable: boolean(),
          auto_dismiss_ms: non_neg_integer() | nil,
          created_at: integer(),
          updated_at: integer() | nil,
          dismiss_ref: reference() | nil
        }

  @doc "Builds a notification from attrs."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    now = Map.get(attrs, :created_at, timestamp())

    %__MODULE__{
      id: attrs |> Map.fetch!(:id) |> to_string(),
      level: validate_level!(Map.fetch!(attrs, :level)),
      title: attrs |> Map.fetch!(:title) |> to_string(),
      body: optional_string(Map.get(attrs, :body)),
      source: optional_string(Map.get(attrs, :source)),
      actions: normalize_actions(Map.get(attrs, :actions, [])),
      dismissable: Map.get(attrs, :dismissable, true),
      auto_dismiss_ms: Map.get(attrs, :auto_dismiss_ms),
      created_at: now,
      updated_at: Map.get(attrs, :updated_at),
      dismiss_ref: nil
    }
  end

  @doc "Returns a copy updated with attrs while preserving creation time."
  @spec update(t(), keyword() | map()) :: t()
  def update(%__MODULE__{} = notification, attrs) when is_list(attrs) do
    update(notification, Map.new(attrs))
  end

  def update(%__MODULE__{} = notification, %{} = attrs) do
    %{
      notification
      | level: attrs |> Map.get(:level, notification.level) |> validate_level!(),
        title: attrs |> Map.get(:title, notification.title) |> to_string(),
        body: optional_string(Map.get(attrs, :body, notification.body)),
        source: optional_string(Map.get(attrs, :source, notification.source)),
        actions: normalize_actions(Map.get(attrs, :actions, notification.actions)),
        dismissable: Map.get(attrs, :dismissable, notification.dismissable),
        auto_dismiss_ms: Map.get(attrs, :auto_dismiss_ms, notification.auto_dismiss_ms),
        updated_at: Map.get(attrs, :updated_at, timestamp())
    }
  end

  @doc "Attaches the auto-dismiss timer reference used to reject stale timer messages."
  @spec with_dismiss_ref(t(), reference() | nil) :: t()
  def with_dismiss_ref(%__MODULE__{} = notification, dismiss_ref) do
    %{notification | dismiss_ref: dismiss_ref}
  end

  @doc "Sets the original creation timestamp when replacing an existing notification."
  @spec with_created_at(t(), integer()) :: t()
  def with_created_at(%__MODULE__{} = notification, created_at) when is_integer(created_at) do
    %{notification | created_at: created_at}
  end

  @doc "Sets the recency timestamp for a notification snapshot or replacement."
  @spec with_updated_at(t(), integer()) :: t()
  def with_updated_at(%__MODULE__{} = notification, updated_at) when is_integer(updated_at) do
    %{notification | updated_at: updated_at}
  end

  @spec validate_level!(level()) :: level()
  defp validate_level!(level) when level in [:info, :warning, :error, :success, :progress],
    do: level

  defp validate_level!(level) do
    raise ArgumentError, "invalid notification level: #{inspect(level)}"
  end

  @spec normalize_actions([Action.t() | keyword() | map()]) :: [Action.t()]
  defp normalize_actions(actions) when is_list(actions) do
    Enum.map(actions, &normalize_action/1)
  end

  @spec normalize_action(Action.t() | keyword() | map()) :: Action.t()
  defp normalize_action(%Action{} = action), do: action
  defp normalize_action(attrs), do: Action.new(attrs)

  @spec optional_string(term()) :: String.t() | nil
  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  @spec timestamp() :: integer()
  defp timestamp, do: System.system_time(:second)
end
