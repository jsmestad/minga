defmodule MingaAgent.InferenceRoute.SetupAction do
  @moduledoc """
  An optional setup entry a route shows in `/model`, such as "Use Claude subscription (Claude Code)".

  Selecting it runs the route's own `availability/2` check off the editor process and reports the result. It never asks for a secret.
  """

  @enforce_keys [:label, :description]
  defstruct @enforce_keys

  @type t :: %__MODULE__{label: String.t(), description: String.t()}

  @doc "Builds a setup action from a label and a description."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, :invalid_setup_action}
  def new(%__MODULE__{} = action), do: action |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: new(:invalid)
  end

  def new(%{label: label, description: description})
      when is_binary(label) and is_binary(description) do
    case {String.trim(label), String.trim(description)} do
      {"", _description} -> {:error, :invalid_setup_action}
      {label, description} -> {:ok, %__MODULE__{label: label, description: description}}
    end
  end

  def new(_attrs), do: {:error, :invalid_setup_action}
end
