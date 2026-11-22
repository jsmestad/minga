defmodule Minga.Buffer.Conflict do
  @moduledoc "Stable values for reading and resolving buffer merge conflicts."

  @typedoc "The inclusive, zero-based marker lines of a conflict at one buffer version."
  @type region :: %{start_line: non_neg_integer(), end_line: non_neg_integer()}

  @typedoc "Conflict coordinates in document order, cursor, and mutation version from one read."
  @type view :: %{
          version: non_neg_integer(),
          cursor: Minga.Buffer.position(),
          entries: [region()]
        }

  @typedoc "Resolve the conflict at an observed cursor line or an exact observed region."
  @type target :: {:cursor, non_neg_integer()} | {:region, region()}

  @typedoc "Keep the current side, incoming side, or both in that order."
  @type choice :: :current | :incoming | :both

  @typedoc "The mutation version produced by a resolution and the number of conflicts left."
  @type resolution :: %{version: non_neg_integer(), remaining: non_neg_integer()}

  @typedoc "Rejected resolutions leave the buffer unchanged."
  @type rejection :: :stale | :not_found | :read_only
end
