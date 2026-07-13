defmodule MingaEditor.Shell.Traditional.GitToast do
  @moduledoc """
  Pure, protocol-independent lifecycle owner for one Git toast.

  Informational and successful toasts are timed. Warning and error toasts are
  sticky. Identity matching makes replacement safe against stale dismissal.
  """

  @type id :: non_neg_integer()
  @type level :: :info | :success | :warning | :error
  @type action :: :pull_and_retry | nil
  @type t :: %__MODULE__{
          id: id(),
          message: String.t() | nil,
          level: level() | nil,
          action: action(),
          timer: reference() | nil
        }

  defstruct id: 0, message: nil, level: nil, action: nil, timer: nil

  @doc "Publishes a latest-wins toast and advances its identity."
  @spec publish(t(), String.t(), level(), action()) :: t()
  def publish(%__MODULE__{} = toast, message, level, action \\ nil)
      when is_binary(message) and level in [:info, :success, :warning, :error] and
             action in [:pull_and_retry, nil] do
    %__MODULE__{id: toast.id + 1, message: message, level: level, action: action}
  end

  @doc "Returns whether this toast level should be auto-dismissed."
  @spec auto_dismiss?(t()) :: boolean()
  def auto_dismiss?(%__MODULE__{message: message, level: level}),
    do: is_binary(message) and level in [:info, :success]

  @doc "Records a timer handle only for the current timed toast identity."
  @spec record_timer(t(), id(), reference()) :: t()
  def record_timer(%__MODULE__{id: id} = toast, id, timer) when is_reference(timer) do
    if auto_dismiss?(toast), do: %{toast | timer: timer}, else: toast
  end

  def record_timer(%__MODULE__{} = toast, _id, _timer), do: toast

  @doc "Dismisses the current toast manually."
  @spec dismiss(t()) :: t()
  def dismiss(%__MODULE__{} = toast), do: clear(toast)

  @doc "Dismisses only when the expected identity is still current."
  @spec dismiss(t(), id()) :: t()
  def dismiss(%__MODULE__{id: id} = toast, id), do: clear(toast)
  def dismiss(%__MODULE__{} = toast, _stale_id), do: toast

  @doc "Times out only a matching timed toast; sticky levels ignore timeout delivery."
  @spec timeout(t(), id()) :: t()
  def timeout(%__MODULE__{id: id} = toast, id) do
    if auto_dismiss?(toast), do: clear(toast), else: toast
  end

  def timeout(%__MODULE__{} = toast, _stale_id), do: toast

  @doc "Returns whether a toast is currently present."
  @spec present?(t()) :: boolean()
  def present?(%__MODULE__{message: message}), do: is_binary(message)

  @spec clear(t()) :: t()
  defp clear(%__MODULE__{message: nil, timer: nil} = toast), do: toast

  defp clear(%__MODULE__{} = toast),
    do: %{toast | message: nil, level: nil, action: nil, timer: nil}
end
