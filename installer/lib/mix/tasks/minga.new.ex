defmodule Mix.Tasks.Minga.New do
  @moduledoc """
  Creates a new Minga editor extension project.

      mix minga.new my_extension

  This generates a complete, compilable extension project with the
  right directory structure, SDK dependency, and `use Minga.Extension`
  boilerplate.

  ## Options

    * `--path` - the directory to create the project in (defaults to the extension name)
  """

  use Mix.Task

  @version "0.1.0"

  @shortdoc "Creates a new Minga editor extension project"

  @switches [path: :string]

  @impl true
  def run(argv) do
    case OptionParser.parse!(argv, strict: @switches) do
      {opts, [name]} ->
        generate(name, opts)

      {_opts, []} ->
        Mix.raise("Expected extension name. Usage: mix minga.new my_extension")

      {_opts, _} ->
        Mix.raise("Expected a single extension name. Usage: mix minga.new my_extension")
    end
  end

  defp generate(name, opts) do
    unless name =~ ~r/^[a-z][a-z0-9_]*$/ do
      Mix.raise(
        "Extension name must start with a lowercase letter and contain only lowercase letters, digits, and underscores. Got: #{name}"
      )
    end

    module = Macro.camelize(name)
    path = Keyword.get(opts, :path, name)
    binding = [name: name, module: module, version: @version]

    if File.exists?(path) do
      Mix.raise("Directory #{path} already exists")
    end

    Mix.shell().info("Creating Minga extension #{name}...")

    File.mkdir_p!(path)
    File.mkdir_p!(Path.join(path, "lib/#{name}"))
    File.mkdir_p!(Path.join(path, "test"))

    templates = [
      {"mix.exs.eex", "mix.exs"},
      {"extension.ex.eex", "lib/#{name}.ex"},
      {"commands.ex.eex", "lib/#{name}/commands.ex"},
      {"extension_test.exs.eex", "test/#{name}_test.exs"},
      {"test_helper.exs.eex", "test/test_helper.exs"},
      {"formatter.exs.eex", ".formatter.exs"},
      {"gitignore.eex", ".gitignore"}
    ]

    for {template, dest} <- templates do
      content = render_template(template, binding)
      dest_path = Path.join(path, dest)
      File.write!(dest_path, content)
      Mix.shell().info("  * creating #{dest}")
    end

    Mix.shell().info("""

    Your Minga extension is ready! Next steps:

        cd #{path}
        mix deps.get
        mix test

    To install in Minga, add to your config:

        extension :#{name},
          path: "#{Path.expand(path)}"

    """)
  end

  defp render_template(name, binding) do
    path = Path.join(template_dir(), name)
    EEx.eval_file(path, binding)
  end

  defp template_dir do
    case Application.app_dir(:minga_new, "templates") do
      path when is_binary(path) ->
        if File.dir?(path), do: path, else: source_template_dir()
    end
  rescue
    _ -> source_template_dir()
  end

  defp source_template_dir do
    __DIR__
    |> Path.join("../../../templates")
    |> Path.expand()
  end
end
