defmodule Minga.RenderModel.UI.FileTree do
  @moduledoc """
  Pre-encoded file tree model.

  The file tree is the most complex single GUI component. It has multiple
  states (hidden, scanning, ready, error, empty), a selection-only fast
  path for cursor movement, and deeply coupled encoding with Rows, git
  status, diagnostics, editing state, and guide columns.

  The builder pre-encodes both the full tree command and the selection-only
  command (when in ready state). The encoder implements three-way cache
  comparison to decide which command to send:

  1. Nothing changed: send nil
  2. Only selection changed (structural fingerprint matches): send selection_encoded
  3. Structural change or state change: send encoded (full command)

  ## Fingerprint shapes

  - `{:ready, structural_fp, selection_fp}` for ready trees
  - `{:file_tree_state, root_path, width, status}` for non-ready states
  - `{:no_tree, root_path}` for hidden/absent trees
  """

  @type fingerprint ::
          {:ready, non_neg_integer(), non_neg_integer()}
          | {:file_tree_state, String.t(), non_neg_integer(), term()}
          | {:no_tree, String.t()}

  @type t :: %__MODULE__{
          encoded: binary(),
          selection_encoded: binary() | nil,
          fingerprint: fingerprint()
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :selection_encoded, :fingerprint]
end
