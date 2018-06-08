require "spec_helper"
require "agent/build"

describe FastlaneCI::Agent::Build do
  let(:yielder) { double("Yielder") }
  let(:build_request) { double("BuildRequest") }
  let(:build) { described_class.new(build_request, yielder) }

  it "has states that are defined in the proto" do
    proto_states = FastlaneCI::Proto::BuildResponse::Status::State.constants
    proto_states.map!{|s| s.downcase.to_s }
    expect(build.states).to contain_exactly(*proto_states)
  end

end
