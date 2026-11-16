defmodule Shop.Pay.Gate do
  @moduledoc """
  Answers `mishka_pay:checkout:before`: refuses every checkout while the site is closed
  (`Shop.Pay.Setting`, `:open`), and stamps every other one with the channel it came from, so the
  metadata shows on the payment at Stripe.
  """

  use MishkaInstaller.Event.Hook, event: "mishka_pay:checkout:before"

  require Ash.Query

  @impl true
  def call(%{checkout: checkout} = state) do
    case open?(checkout.tenant) do
      true ->
        metadata = Map.put(checkout.metadata || %{}, "channel", "demo-shop")
        {:reply, %{state | checkout: %{checkout | metadata: metadata}}}

      false ->
        {:reply, %{state | refused: "the shop is closed"}}
    end
  end

  defp open?(tenant) do
    Shop.Pay.Setting
    |> Ash.Query.filter(tenant == ^tenant)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{open: false}} -> false
      _open_or_unset -> true
    end
  end
end
