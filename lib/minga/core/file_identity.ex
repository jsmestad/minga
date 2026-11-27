defmodule Minga.Core.FileIdentity do
  @moduledoc "Compares filesystem entries independently of the paths used to reach them."

  @type t :: {integer(), integer(), integer(), File.Stat.type()}

  @doc "Returns the identity of the stat result. Use lstat to identify a link itself."
  @spec from_stat(File.Stat.t()) :: t()
  def from_stat(%File.Stat{} = stat) do
    {stat.major_device, stat.minor_device, stat.inode, stat.type}
  end
end
