defmodule MingaEditor.NativeIPC.OperationNativeResult do
  @moduledoc "Authenticated frontend evidence for one native presentation operation."

  alias MingaEditor.NativeIPC.OperationReceipt
  alias MingaEditor.NativeIPC.OperationReceipt.Evidence

  @enforce_keys [:operation_id, :target_token, :outcome, :evidence]
  defstruct [:operation_id, :target_token, :outcome, :evidence, :last_visible]

  @type t :: %__MODULE__{
          operation_id: pos_integer(),
          target_token: non_neg_integer(),
          outcome: OperationReceipt.outcome(),
          evidence: Evidence.t(),
          last_visible: Evidence.t() | nil
        }
end
