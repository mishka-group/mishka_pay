defmodule Shop.Pay.Stats do
  @moduledoc "Counts and sums of the shop's payments by status, in one query."

  import Ecto.Query

  @doc "Each status with its count, the money asked and the money refunded, in USD."
  def by_status do
    Shop.Repo.all(
      from p in "payments",
        group_by: p.status,
        select: %{
          status: p.status,
          count: count(),
          amount: sum(p.amount),
          refunded: sum(p.amount_refunded)
        }
    )
  end
end
