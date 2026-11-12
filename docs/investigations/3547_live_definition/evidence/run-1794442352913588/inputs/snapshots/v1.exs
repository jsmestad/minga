defmodule R0Definition.Helper do
  def revision, do: :v1
  def valid?, do: true
  def compute(n, x), do: 10 + n + x
end

defmodule R0Definition.Left do
  def upgrade(model), do: {:ok, %{model | schema: 1}}
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v1, R0Definition.Helper.revision(), 100 + R0Definition.Helper.compute(model.n, input)}
  end
end

defmodule R0Definition.Right do
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v1, R0Definition.Helper.revision(), 1000 + R0Definition.Helper.compute(model.n, input)}
  end
end
