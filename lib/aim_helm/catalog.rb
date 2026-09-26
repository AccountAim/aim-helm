# frozen_string_literal: true

module AimHelm
  # Loads pricing and capability rows from a YAML catalog into a frozen `id => Catalog::Model`
  # hash. An `aliases` entry maps a second id to the target's row, id included, so a request for
  # "gpt-5.6-sol" goes out as "gpt-6-sol". `Catalog.default` memoizes the bundled models.yml.
  module Catalog
    CATALOG_PATH = File.expand_path("models.yml", __dir__)

    module_function

    def load(path, base: {})
      data = YAML.safe_load_file(path)
      models = base.merge(
        data.fetch("models", {}).to_h do |id, attributes|
          [id, Catalog::Model.new(id:, **attributes.transform_keys(&:to_sym))]
        end,
      )

      aliases = data.fetch("aliases", {})
      aliases.each_key { models[it] = models.fetch(resolve(it, aliases)) }

      models.freeze
    end

    # The model at the end of an alias chain, in any order: old -> latest -> model.
    def resolve(name, aliases)
      chain = [name]
      while aliases.key?(chain.last) && chain.size <= aliases.size
        chain << aliases.fetch(chain.last)
      end
      raise ArgumentError, "alias cycle: #{chain.join(" -> ")}" if aliases.key?(chain.last)

      chain.last
    end

    def default = @default ||= load(CATALOG_PATH)
  end
end
