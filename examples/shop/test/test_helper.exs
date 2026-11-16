MishkaPay.Test.setup!()
# Stripe registers a moment after boot: the first test must not come first.
MishkaPay.Test.await_plugin!(MishkaPay.Providers.Stripe)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Shop.Repo, :manual)
