defmodule R0Definition.Helper do
  def revision, do: :rejected
  def valid?, do: false
  def compute(n, x), do: 90 + n + x
end

defmodule R0Definition.Left do
  def upgrade(model), do: {:ok, %{model | schema: 9}}
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:rejected, R0Definition.Helper.revision(), 900 + R0Definition.Helper.compute(model.n, input)}
  end
end

defmodule R0Definition.Right do
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:rejected, R0Definition.Helper.revision(), 9000 + R0Definition.Helper.compute(model.n, input)}
  end
end
