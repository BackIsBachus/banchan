defmodule Banchan.Commissions.CommissionFilter do
  @moduledoc """
  Filters applied to the commissions dashboard.
  """
  defstruct [:search, :client, :studio, :statuses, :show_archived]

  @types %{
    search: :string,
    client: :string,
    studio: :string,
    statuses: {:array, :string},
    show_archived: :boolean
  }

  import Ecto.Changeset

  def changeset(%__MODULE__{} = filter, attrs \\ %{}) do
    {filter, @types}
    |> cast(attrs, Map.keys(@types))
  end
end
