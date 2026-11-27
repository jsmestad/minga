defmodule Minga.Core.FileIdentity do
  @moduledoc "Compares filesystem entries independently of the paths used to reach them."

  @type t ::
          {non_neg_integer() | :undefined, non_neg_integer() | :undefined,
           non_neg_integer() | :undefined,
           :device | :directory | :regular | :other | :symlink | :undefined}

  @doc "Returns the identity of the stat result. Use lstat to identify a link itself."
  @spec from_stat(File.Stat.t()) :: t()
  def from_stat(%File.Stat{} = stat) do
    {stat.major_device, stat.minor_device, stat.inode, stat.type}
  end
end
