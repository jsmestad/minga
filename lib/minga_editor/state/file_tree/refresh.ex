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

  @typedoc "Semantic correlation for the newest admitted refresh request."
  @type current_request :: %{token: request_token(), root: String.t()}

  @type t :: %__MODULE__{
          debounce: debounce_token() | nil,
          current: current_request() | nil
        }

  defstruct debounce: nil, current: nil

  @doc "Records one debounce intent, leaving an existing timer authoritative."
  @spec request_debounce(t(), debounce_token()) :: {:scheduled | :already_scheduled, t()}
  def request_debounce(%__MODULE__{debounce: nil} = refresh, token) when is_reference(token) do
    {:scheduled, %{refresh | debounce: token}}
  end

  def request_debounce(%__MODULE__{} = refresh, token) when is_reference(token) do
    {:already_scheduled, refresh}
  end

  @doc "Consumes only the currently correlated debounce timer message."
  @spec debounce_elapsed(t(), debounce_token()) :: {:current | :stale, t()}
  def debounce_elapsed(%__MODULE__{debounce: token} = refresh, token) when is_reference(token) do
    {:current, %{refresh | debounce: nil}}
  end

  def debounce_elapsed(%__MODULE__{} = refresh, token) when is_reference(token) do
    {:stale, refresh}
  end

  @doc "Correlates the newest admitted scheduler request with its scanned root."
  @spec request_admitted(t(), String.t(), request_token()) :: t()
  def request_admitted(%__MODULE__{} = refresh, root, token)
      when is_binary(root) and is_reference(token) do
    %{refresh | current: %{root: Path.expand(root), token: token}}
  end

  @doc "Classifies and consumes a terminal result for the semantic current request."
  @spec request_finished(t(), String.t(), request_token()) ::
          {:current | :stale, t()}
  def request_finished(
        %__MODULE__{current: %{root: root, token: token}} = refresh,
        root,
        token
      )
      when is_binary(root) and is_reference(token) do
    {:current, %{refresh | current: nil}}
  end

  def request_finished(%__MODULE__{} = refresh, root, token)
      when is_binary(root) and is_reference(token) do
    {:stale, refresh}
  end

  @doc "Invalidates every timer and result correlation when the tree lifecycle changes."
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{} = refresh), do: %{refresh | debounce: nil, current: nil}
end
