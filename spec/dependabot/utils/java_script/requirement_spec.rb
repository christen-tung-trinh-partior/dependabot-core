# frozen_string_literal: true

require "spec_helper"
require "dependabot/utils/java_script/requirement"
require "dependabot/utils/java_script/version"

RSpec.describe Dependabot::Utils::JavaScript::Requirement do
  subject(:requirement) { described_class.new(requirement_string) }
  let(:requirement_string) { ">=1.0.0" }

  describe ".new" do
    it { is_expected.to be_a(described_class) }

    context "with an exact version specified" do
      let(:requirement_string) { "1.0.0" }
      it { is_expected.to eq(described_class.new("1.0.0")) }
    end

    context "with a caret version specified" do
      let(:requirement_string) { "^1.0.0" }
      it { is_expected.to eq(described_class.new(">= 1.0.0", "< 2.0.0")) }
    end

    context "with a ~ version specified" do
      let(:requirement_string) { "~1.5.1" }
      it { is_expected.to eq(described_class.new("~> 1.5.1")) }
    end

    context "with a ~> version specified" do
      let(:requirement_string) { "~>1.5.1" }
      it { is_expected.to eq(described_class.new("~> 1.5.1")) }
    end

    context "with only a *" do
      let(:requirement_string) { "*" }
      it { is_expected.to eq(described_class.new("~> 0")) }
    end

    context "with a *" do
      let(:requirement_string) { "1.*" }
      it { is_expected.to eq(described_class.new("~> 1.0")) }
    end

    context "with an x" do
      let(:requirement_string) { "^1.1.x" }
      it { is_expected.to eq(described_class.new(">= 1.1", "< 2.0")) }
    end
  end
end
