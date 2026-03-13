defmodule Minga.Mode.ExtensionConfirmState do
  @moduledoc """
  FSM state for the extension update confirmation dialog.

  Holds the list of pending updates, the current index being shown,
  and whether the user wants details for the current item.
  """

  @enforce_keys [:updates]
  defstruct updates: [],
            current: 0,
            accepted: [],
            show_details: false

  @typedoc "An update summary for display in the confirmation dialog."
  @type update_entry :: %{
          name: atom(),
          source_type: :git | :hex,
          old_ref: String.t(),
          new_ref: String.t(),
          commit_count: non_neg_integer(),
          branch: String.t() | nil,
          pinned: boolean()
        }

  @type t :: %__MODULE__{
          updates: [update_entry()],
          current: non_neg_integer(),
          accepted: [non_neg_integer()],
          show_details: boolean()
        }
end
