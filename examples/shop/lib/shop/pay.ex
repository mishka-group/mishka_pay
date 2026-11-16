defmodule Shop.Pay do
  @moduledoc """
  The shop's payments, on Mishka Pay's Ash layer: the payments table, the webhook inbox and the
  per-site settings Mishka Pay reads at runtime.
  """

  use Ash.Domain, otp_app: :shop

  resources do
    resource Shop.Pay.WebhookEvent
    resource Shop.Pay.Payment
    resource Shop.Pay.Subscription
    resource Shop.Pay.Customer
    resource Shop.Pay.Dispute
    resource Shop.Pay.ClockRun
    resource Shop.Pay.Setting
    resource Shop.Catalog.Product
    # What the site manages from its admin, each on its Mishka Pay kind.
    resource Shop.Pay.CatalogProduct
    resource Shop.Pay.CatalogPrice
    resource Shop.Pay.Coupon
    resource Shop.Pay.PromotionCode
    resource Shop.Pay.PaymentLink
    resource Shop.Pay.Invoice
  end
end
