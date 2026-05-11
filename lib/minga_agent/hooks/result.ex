defmodule MingaAgent.Hooks.Result do
  @moduledoc """
  Structured result returned by agent hook runners.

  `:allow` means execution may continue. `:veto` means the hook blocked the
  tool call and the tool callback must not run.
  """

  alias MingaAgent.Hooks.Hook

  @typedoc "Why a hook vetoed or failed."
  @type reason :: {:exit, non_neg_integer()} | :timeout | {:failed_to_start, term()}

  @typedoc "Structured hook result."
  @type t :: %__MODULE__{
          status: :allow | :veto,
          hook: Hook.t() | nil,
          stderr: String.t(),
          exit_status: non_neg_integer() | nil,
          reason: reason() | nil
        }

  defstruct status: :allow, hook: nil, stderr: "", exit_status: nil, reason: nil

  @doc "Builds an allow result."
  @spec allow(Hook.t() | nil) :: t()
  def allow(hook \\ nil), do: %__MODULE__{status: :allow, hook: hook}

  @doc "Builds a veto result."
  @spec veto(Hook.t(), String.t(), reason()) :: t()
  def veto(%Hook{} = hook, stderr, {:exit, status}) when is_binary(stderr) do
    %__MODULE__{
      status: :veto,
      hook: hook,
      stderr: stderr,
      exit_status: status,
      reason: {:exit, status}
    }
  end

  def veto(%Hook{} = hook, stderr, reason) when is_binary(stderr) do
    %__MODULE__{status: :veto, hook: hook, stderr: stderr, reason: reason}
  end

  @doc "Returns a concise user-facing error for a veto result."
  @spec message(t()) :: String.t()
  def message(%__MODULE__{status: :veto, stderr: stderr, reason: :timeout, hook: hook}) do
    label = event_label(hook)

    details =
      non_empty(stderr) || "#{label} hook timed out after #{hook.timeout_ms}ms and was killed"

    "#{label} hook vetoed execution: #{details}"
  end

  def message(%__MODULE__{status: :veto, stderr: stderr, reason: {:exit, status}, hook: hook}) do
    label = event_label(hook)
    details = non_empty(stderr) || "hook exited with status #{status}"
    "#{label} hook vetoed execution: #{details}"
  end

  def message(%__MODULE__{status: :veto, stderr: stderr, hook: hook}) do
    label = event_label(hook)
    details = non_empty(stderr) || "hook failed"
    "#{label} hook vetoed execution: #{details}"
  end

  def message(%__MODULE__{hook: hook}) do
    "#{event_label(hook)} hook allowed execution"
  end

  @spec event_label(Hook.t() | nil) :: String.t()
  defp event_label(%Hook{event: event}), do: Hook.event_label(event)
  defp event_label(nil), do: "Hook"

  @spec non_empty(String.t()) :: String.t() | nil
  defp non_empty(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: nil, else: trimmed
  end
end
