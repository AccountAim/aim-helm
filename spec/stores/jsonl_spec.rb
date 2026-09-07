# frozen_string_literal: true

RSpec.describe AimHelm::Stores::JSONL do
  around do |example|
    Dir.mktmpdir("aim_helm-jsonl-store") do |dir|
      @store_dir = dir
      example.run
    end
  end

  let(:store) { described_class.new(dir: @store_dir) }
  let(:prepare_session) { ->(_id) {} }

  it_behaves_like "a AimHelm store"
end
