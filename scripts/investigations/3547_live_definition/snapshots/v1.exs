defmodule R0Definition.Helper do
  @moduledoc "Owned arithmetic helper for the stable-name v1 definition."
  @type revision :: :v1
  @spec revision() :: revision()
  def revision, do: :v1
  @spec valid?() :: boolean()
  def valid?, do: true
  @spec compute(integer(), integer()) :: integer()
  def compute(n, x), do: 10 + n + x
end

defmodule R0Definition.Left do
  @moduledoc "First v1 entry point and inert-instance upgrade callback."
  @type model :: %{schema: pos_integer(), n: integer(), kind: :modern | :legacy}
  @type result :: {R0Definition.Helper.revision(), R0Definition.Helper.revision(), integer()}
  @spec upgrade(model()) :: {:ok, model()}
  def upgrade(model), do: {:ok, %{model | schema: 1}}
  @spec run(model(), integer(), map()) :: result()
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v1, R0Definition.Helper.revision(), 100 + R0Definition.Helper.compute(model.n, input)}
  end
end

defmodule R0Definition.Right do
  @moduledoc "Second v1 entry point sharing the same owned helper."
  @type result :: R0Definition.Left.result()
  @spec run(R0Definition.Left.model(), integer(), map()) :: result()
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v1, R0Definition.Helper.revision(), 1000 + R0Definition.Helper.compute(model.n, input)}
  end
end
