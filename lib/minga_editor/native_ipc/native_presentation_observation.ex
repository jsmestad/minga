defmodule MingaEditor.NativeIPC.NativePresentationObservation do
  @moduledoc "Last native editor presentation proven at the Metal completion and focus boundary."

  @enforce_keys [
    :target_token,
    :application_revision,
    :generation,
    :frame_seq,
    :window_id,
    :focus_ready
  ]
  defstruct [
    :target_token,
    :application_revision,
    :generation,
    :frame_seq,
    :window_id,
    :focus_ready
  ]

  @type t :: %__MODULE__{
          target_token: non_neg_integer(),
          application_revision: non_neg_integer(),
          generation: non_neg_integer(),
          frame_seq: non_neg_integer(),
          window_id: non_neg_integer(),
          focus_ready: boolean()
        }

  @doc "Returns the stable JSON projection used by semantic inspection."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = observation) do
    %{
      "status" => "presented",
      "target_token" => Integer.to_string(observation.target_token),
      "application_revision" => observation.application_revision,
      "generation" => observation.generation,
      "frame_sequence" => observation.frame_seq,
      "window_id" => observation.window_id,
      "native_focus" => observation.focus_ready
    }
  end
end
