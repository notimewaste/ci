require "spec_helper"
require "agent/build"

RSpec::Matchers.define :proto_message do |message|
  match do |actual|
    message = message.to_h unless message.is_a?(Symbol)
    expect(actual.to_h).to include(message)
  end
end

describe FastlaneCI::Agent::Build do
  let(:yielder) { double("Yielder") }
  let(:build_request) { double("BuildRequest") }
  let(:build) { described_class.new(build_request, yielder) }

  it "has states that are defined in the proto" do
    proto_states = FastlaneCI::Proto::BuildResponse::Status::State.constants
    proto_states.map!{|s| s.downcase.to_s }
    expect(build.states).to contain_exactly(*proto_states)
  end

  describe '#throw' do
    it "sends a state change and an exception back to the client" do
      expect(yielder).to receive(:<<).with(proto_message(status: { state: :BROKEN, description: "my dog hates technology" }))
      expect(yielder).to receive(:<<).with(proto_message(:build_error))
      begin
        raise 'my dog hates technology'
      rescue StandardError => exception
        build.throw(exception)
      end
    end
  end
end
