defmodule MingaEditor.UI.Notification.Action do
  @moduledoc """
  Inline action shown on a GUI notification.

  The action id is the stable wire value sent back by native frontends. The optional dispatch value tells the BEAM how to route the click.
  """

  @enforce_keys [:id, :label]
  defstruct [:id, :label, dispatch: nil]

  @typedoc "BEAM-side routing target for a notification action."
  @type dispatch :: {:command, atom()} | {:event, atom(), term()} | nil

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          dispatch: dispatch()
        }

  @doc "Builds an action from attrs, normalizing ids and labels to strings."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    dispatch = Map.get(attrs, :dispatch)

    %__MODULE__{
      id: attrs |> Map.fetch!(:id) |> to_string(),
      label: attrs |> Map.fetch!(:label) |> to_string(),
      dispatch: validate_dispatch!(dispatch)
    }
  end

  @spec validate_dispatch!(dispatch()) :: dispatch()
  defp validate_dispatch!(nil), do: nil
  defp validate_dispatch!({:command, command} = dispatch) when is_atom(command), do: dispatch
  defp validate_dispatch!({:event, event, _payload} = dispatch) when is_atom(event), do: dispatch

  defp validate_dispatch!(dispatch) do
    raise ArgumentError, "invalid notification action dispatch: #{inspect(dispatch)}"
  end
end
