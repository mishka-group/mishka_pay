# The Ash layer

With Ash, Mishka Pay keeps payments, subscriptions, customers and disputes in your own resources,
read again from the provider whenever a webhook says something changed, and stores every webhook
in an inbox worked by AshOban with retries.

```elixir
defmodule MyApp.Pay.Payment do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :payment
  end

  postgres do
    table "pay_payments"
    repo MyApp.Repo
  end
end
```

`mix igniter.install mishka_pay --ash` writes the domain and the five resources (inbox, payment,
subscription, customer, dispute), then `mix ash.codegen mishka_pay`. Each resource makes its own
listener (`<Resource>.MishkaPayListener`), which the installer adds to the application's children;
by hand, `MishkaPay.Ash.listeners(MyApp.Pay)` lists them all in the domain's order.

## What each kind does

- **inbox**: stores each verified webhook once and works it with retries (10 tries, the reason of
  each failure kept on the row).
- **payment**: `:sync` reads a payment from the provider; `:start_checkout`; `:refund`.
- **subscription**: `:sync`, `:cancel`, `:resume`, `:change` (plan or quantity, with proration),
  `:pause`, `:resume_collection`.
- **customer**: `:register`, `:sync`, `:edit`, `:portal`.
- **dispute**: `:sync`, `:submit_evidence`, `:accept`.

Every action asks the provider before its transaction and writes what the provider answered, then
fires `mishka_pay:<kind>:changed`. The `mishka_pay` section takes `actions`, `listen?`,
`announce?`, `code_interface?` and `belongs_to_user`; see `MishkaPay.Ash.Resource`.

## Real time

```elixir
defmodule MyApp.Pay.Broadcast do
  use MishkaPay.PubSub, pubsub: MyApp.PubSub
end
```

Each change goes to `MishkaPay.PubSub.topic(kind)` and `MishkaPay.PubSub.topic(kind, site_id)`.
