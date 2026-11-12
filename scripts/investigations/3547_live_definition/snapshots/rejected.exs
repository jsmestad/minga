defmodule R0Definition.Helper do
  @moduledoc "Owned candidate helper that fails global definition validation."
  @type revision :: :rejected
  @spec revision() :: revision()
  def revision, do: :rejected
  @spec valid?() :: boolean()
  def valid?, do: false
  @spec compute(integer(), integer()) :: integer()
  def compute(n, x), do: 90 + n + x
end

defmodule R0Definition.Left do
  @moduledoc "First rejected-candidate entry point, installed but never admitted."
  @type model :: %{schema: pos_integer(), n: integer(), kind: :modern | :legacy}
  @type result :: {R0Definition.Helper.revision(), R0Definition.Helper.revision(), integer()}
  @spec upgrade(model()) :: {:ok, model()}
  def upgrade(model), do: {:ok, %{model | schema: 9}}
  @spec run(model(), integer(), map()) :: result()
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:rejected, R0Definition.Helper.revision(), 900 + R0Definition.Helper.compute(model.n, input)}
  end
end

defmodule R0Definition.Right do
  @moduledoc "Second rejected-candidate entry point sharing the invalid helper."
  @type result :: R0Definition.Left.result()
  @spec run(R0Definition.Left.model(), integer(), map()) :: result()
  def run(model, input, context) do
    R0.Gate.before_helper(context)

    {:rejected, R0Definition.Helper.revision(),
     9000 + R0Definition.Helper.compute(model.n, input)}
  end
end
