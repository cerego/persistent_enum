module PersistentEnum
  class Railtie < Rails::Railtie

    # On ActionDispatch::Reloader prepare!, ensure that registered acts_as_enums
    # are eager-reloaded. This reduces the chance that they'll be reloaded during
    # a transaction.
    config.to_prepare do
      ActsAsEnum.rerequire_known_enumerations
    end
  end
end
