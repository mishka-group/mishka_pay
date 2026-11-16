# The demo shop's products and the site's payment settings. Run with `mix run priv/repo/seeds.exs`
# (`mix setup` and `mix ecto.reset` run it). Running it again updates the rows, never duplicates.

products = [
  %{slug: "ebook", name: "Elixir ebook", price: "19.99", icon: "hero-book-open"},
  %{slug: "course", name: "LiveView course", price: "49.00", icon: "hero-play-circle"},
  %{slug: "stickers", name: "Sticker pack", price: "4.50", icon: "hero-sparkles"},
  %{slug: "workshop", name: "Phoenix workshop", price: "129.00", icon: "hero-academic-cap"},
  %{slug: "ashbook", name: "Ash framework book", price: "34.00", icon: "hero-book-open"},
  %{slug: "hoodie", name: "Elixir hoodie", price: "39.00", icon: "hero-gift"},
  # Plans, sold as subscriptions. txcd_10103001 is software as a service.
  %{
    slug: "pro-monthly",
    name: "Pro plan, monthly",
    price: "9.00",
    icon: "hero-bolt",
    interval: :month,
    tax_code: "txcd_10103001"
  },
  %{
    slug: "pro-yearly",
    name: "Pro plan, yearly",
    price: "90.00",
    icon: "hero-bolt",
    interval: :year,
    tax_code: "txcd_10103001"
  },
  %{
    slug: "team-monthly",
    name: "Team plan, 14-day trial",
    price: "29.00",
    icon: "hero-user-group",
    interval: :month,
    trial_days: 14,
    tax_code: "txcd_10103001"
  }
]

for {product, position} <- Enum.with_index(products) do
  Ash.create!(Shop.Catalog.Product, Map.put(product, :position, position),
    action: :seed,
    authorize?: false
  )
end

# The site "demo" refunds once, takes the Stripe account's merchant-of-record default and is open.
Ash.create!(Shop.Pay.Setting, %{tenant: "demo", refunds: :once, open: true},
  action: :save,
  authorize?: false
)

IO.puts("Seeded #{length(products)} products and the demo site's settings.")
