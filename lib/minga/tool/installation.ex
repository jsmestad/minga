defmodule Minga.Tool.Installation do
  @moduledoc """
  Represents an installed tool with its metadata.

  An installation is created by `Tool.Manager` after a successful install
  and persisted as a `receipt.json` file alongside the tool's binaries.
  The ETS cache holds these structs for fast lookups.

  ## Fields

  - `:name` - tool atom matching the recipe name
  - `:version` - installed version string
  - `:installed_at` - UTC datetime of installation
  - `:method` - installer method used (mirrors the recipe's method)
  - `:path` - absolute path to the tool's directory
  """

  @enforce_keys [:name, :version, :installed_at, :method, :path]
  defstruct [:name, :version, :installed_at, :method, :path]

  @type t :: %__MODULE__{
          name: atom(),
          version: String.t(),
          installed_at: DateTime.t(),
          method: :npm | :pip | :cargo | :go_install | :github_release,
          path: String.t()
        }

  @doc "Encodes an installation to a map suitable for JSON serialization."
  @spec to_receipt(t()) :: map()
  def to_receipt(%__MODULE__{} = inst) do
    %{
      "name" => Atom.to_string(inst.name),
      "version" => inst.version,
      "installed_at" => DateTime.to_iso8601(inst.installed_at),
      "method" => Atom.to_string(inst.method),
      "path" => inst.path
    }
  end

  @doc "Decodes a receipt map (from JSON) into an Installation struct."
  @spec from_receipt(map()) :: {:ok, t()} | :error
  def from_receipt(
        %{"name" => name, "version" => version, "method" => method, "path" => path} = receipt
      ) do
    with {:ok, dt, _offset} <-
           DateTime.from_iso8601(receipt["installed_at"] || "1970-01-01T00:00:00Z") do
      {:ok,
       %__MODULE__{
         name: String.to_existing_atom(name),
         version: version,
         installed_at: dt,
         method: String.to_existing_atom(method),
         path: path
       }}
    end
  rescue
    ArgumentError -> :error
  end

  def from_receipt(_), do: :error
end
