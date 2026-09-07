# frozen_string_literal: true

module AimHelm
  # Installs the Active Record store and Active Job dispatcher on Rails boot, keeping Rails out of
  # the gem's dependencies.
  class Railtie < Rails::Railtie
    initializer "aim_helm.active_record" do
      ActiveSupport.on_load(:active_record) do
        require "aim_helm/stores/active_record"
      end
    end

    initializer "aim_helm.active_job" do
      ActiveSupport.on_load(:active_job) do
        require "aim_helm/active_job"
      end
    end
  end
end
