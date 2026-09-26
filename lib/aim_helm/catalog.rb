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

      data.fetch("aliases", {}).each do |name, target|
        models[name] = models.fetch(target)
      end

      models.freeze
    end

    def default = @default ||= load(CATALOG_PATH)
  end
end
