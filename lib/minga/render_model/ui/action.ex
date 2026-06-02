defmodule Minga.RenderModel.UI.Action do
  @moduledoc """
  Semantic UI action metadata shared by render-model surfaces.

  Actions are declarative. They may name an editor action to execute when explicit input dispatches the action, but they never carry extension callbacks or arbitrary render-time code.
  """

  @typedoc "Semantic action style hint for frontends."
  @type kind :: :primary | :secondary | :destructive | :link | :toggle

  @typedoc "Editor action dispatched through `MingaEditor.Commands.execute/2`."
  @type editor_action :: atom() | tuple() | nil

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          kind: kind(),
          icon: String.t() | nil,
          enabled?: boolean(),
          confirm: String.t() | nil,
          payload: map(),
          editor_action: editor_action()
        }

  @enforce_keys [:id, :label]
  defstruct id: nil,
            label: nil,
            kind: :secondary,
            icon: nil,
            enabled?: true,
            confirm: nil,
            payload: %{},
            editor_action: nil

  @doc "Builds an action from a struct, map, or keyword list."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = action), do: validate(action)

  def new(attrs) when is_map(attrs) do
    with :ok <- reject_callback_handler(attrs),
         {:ok, id} <- required_string(attrs, :id),
         {:ok, label} <- required_string(attrs, :label),
         {:ok, kind} <- kind(Map.get(attrs, :kind, :secondary)),
         {:ok, icon} <- optional_string(Map.get(attrs, :icon), :icon),
         {:ok, enabled?} <- boolean(Map.get(attrs, :enabled?, true), :enabled?),
         {:ok, confirm} <- optional_string(Map.get(attrs, :confirm), :confirm),
         {:ok, payload} <- payload(Map.get(attrs, :payload, %{})),
         {:ok, editor_action} <- editor_action(Map.get(attrs, :editor_action)) do
      validate(%__MODULE__{
        id: id,
        label: label,
        kind: kind,
        icon: icon,
        enabled?: enabled?,
        confirm: confirm,
        payload: payload,
        editor_action: editor_action
      })
    end
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs |> Map.new() |> new()
    else
      {:error, {:invalid, :attrs, attrs}}
    end
  end

  def new(attrs), do: {:error, {:invalid, :attrs, attrs}}

  @doc "Returns true when the action can be dispatched."
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{enabled?: enabled?}), do: enabled?

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  defp validate(
         %__MODULE__{
           id: id,
           label: label,
           kind: kind,
           icon: icon,
           enabled?: enabled?,
           confirm: confirm,
           payload: payload,
           editor_action: editor_action
         } = action
       ) do
    with {:ok, _id} <- required_binary_value(id, :id),
         {:ok, _label} <- required_binary_value(label, :label),
         {:ok, _kind} <- kind(kind),
         {:ok, _icon} <- optional_string(icon, :icon),
         {:ok, _enabled?} <- boolean(enabled?, :enabled?),
         {:ok, _confirm} <- optional_string(confirm, :confirm),
         {:ok, _payload} <- payload(payload),
         {:ok, _editor_action} <- editor_action(editor_action) do
      {:ok, action}
    end
  end

  @spec reject_callback_handler(map()) :: :ok | {:error, term()}
  defp reject_callback_handler(%{handler: _handler}), do: {:error, {:unsupported, :handler}}
  defp reject_callback_handler(_attrs), do: :ok

  @spec required_string(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp required_string(attrs, key), do: required_binary_value(Map.get(attrs, key), key)

  @spec required_binary_value(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp required_binary_value(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary_value(_value, key), do: {:error, {:invalid, key}}

  @spec optional_string(term(), atom()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_string(nil, _key), do: {:ok, nil}
  defp optional_string("", _key), do: {:ok, nil}
  defp optional_string(value, _key) when is_binary(value), do: {:ok, value}
  defp optional_string(value, key), do: {:error, {:invalid, key, value}}

  @spec boolean(term(), atom()) :: {:ok, boolean()} | {:error, term()}
  defp boolean(value, _key) when is_boolean(value), do: {:ok, value}
  defp boolean(value, key), do: {:error, {:invalid, key, value}}

  @spec kind(term()) :: {:ok, kind()} | {:error, term()}
  defp kind(kind) when kind in [:primary, :secondary, :destructive, :link, :toggle],
    do: {:ok, kind}

  defp kind(other), do: {:error, {:invalid, :kind, other}}

  @spec payload(term()) :: {:ok, map()} | {:error, term()}
  defp payload(payload) when is_map(payload), do: {:ok, payload}
  defp payload(_payload), do: {:error, {:invalid, :payload}}

  @spec editor_action(term()) :: {:ok, editor_action()} | {:error, term()}
  defp editor_action(nil), do: {:ok, nil}
  defp editor_action(editor_action) when is_atom(editor_action), do: {:ok, editor_action}
  defp editor_action(editor_action) when is_tuple(editor_action), do: {:ok, editor_action}
  defp editor_action(other), do: {:error, {:invalid, :editor_action, other}}
end
