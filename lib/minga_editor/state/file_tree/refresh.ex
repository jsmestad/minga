defmodule MingaEditor.State.FileTree.Refresh do
  @moduledoc """
  Pure semantic ownership for file-tree refresh intent.

  The effect scheduler owns worker lifecycle, queueing, cancellation, and terminal
  delivery. This value owns only the current debounce token and the newest
  request whose result may still update the file tree.
  """

  @typedoc "A token carried by one debounce timer message."
  @type debounce_token :: reference()

  @typedoc "A scheduler request token correlated with the root it scanned."
  @type request_token :: reference()

  @type request :: %{token: request_token()}

  @typedoc "Refresh debounce, admission, and bounded-admission retry correlation."
  @type phase ::
          {:idle, non_neg_integer()}
          | {:debounced, debounce_token(), non_neg_integer()}
          | {:admitted, String.t(), request()}

  @type t :: %__MODULE__{phase: phase()}

  defstruct phase: {:idle, 0}

  @doc "Records one debounce intent, leaving an existing timer authoritative and invalidating older result authority."
  @spec request_debounce(t(), debounce_token()) :: {:scheduled | :already_scheduled, t()}
  def request_debounce(
        %__MODULE__{phase: {:debounced, existing_token, _attempt}} = refresh,
        token
      )
      when is_reference(token) do
    {:already_scheduled, %{refresh | phase: {:debounced, existing_token, 0}}}
  end

  def request_debounce(%__MODULE__{} = refresh, token) when is_reference(token) do
    {:scheduled, %{refresh | phase: {:debounced, token, 0}}}
  end

  @doc "Re-arms one correlated debounce after scheduler admission pressure."
  @spec retry_debounce(t(), debounce_token()) :: {pos_integer(), t()}
  def retry_debounce(%__MODULE__{phase: {:idle, attempt}} = refresh, token)
      when is_reference(token) do
    next_attempt = attempt + 1
    {next_attempt, %{refresh | phase: {:debounced, token, next_attempt}}}
  end

  @doc "Consumes only the currently correlated debounce timer message."
  @spec debounce_elapsed(t(), debounce_token()) ::
          {:current, non_neg_integer(), t()} | {:stale, t()}
  def debounce_elapsed(%__MODULE__{phase: {:debounced, token, attempt}} = refresh, token)
      when is_reference(token) do
    {:current, attempt, %{refresh | phase: {:idle, attempt}}}
  end

  def debounce_elapsed(%__MODULE__{} = refresh, token) when is_reference(token) do
    {:stale, refresh}
  end

  @doc "Correlates the newest admitted scheduler request with its scanned root."
  @spec request_admitted(t(), String.t(), request_token()) :: t()
  def request_admitted(%__MODULE__{phase: {:idle, _attempt}} = refresh, root, token)
      when is_binary(root) and is_reference(token) do
    %{refresh | phase: {:admitted, Path.expand(root), %{token: token}}}
  end

  @doc "Classifies and consumes a terminal result for the semantic current request."
  @spec request_finished(t(), String.t(), request_token()) ::
          {:current | :stale, t()}
  def request_finished(
        %__MODULE__{phase: {:admitted, root, %{token: token}}} = refresh,
        root,
        token
      )
      when is_binary(root) and is_reference(token) do
    {:current, %{refresh | phase: {:idle, 0}}}
  end

  def request_finished(%__MODULE__{} = refresh, root, token)
      when is_binary(root) and is_reference(token) do
    {:stale, refresh}
  end

  @doc "Invalidates every timer and result correlation when the tree lifecycle changes."
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{} = refresh), do: %{refresh | phase: {:idle, 0}}
end
