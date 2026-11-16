MishkaPay.Test.setup!()
MishkaPay.Test.await_plugin!(MishkaPay.Providers.Stripe)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Shop.Repo, :manual)
