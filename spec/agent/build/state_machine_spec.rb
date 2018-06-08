require "spec_helper"
require "agent/build/state_machine"

describe FastlaneCI::Agent::StateMachine do

  # use a build class here to decouple from other side-effects
  class Build
    prepend FastlaneCI::Agent::StateMachine

    def run
      'some return value'
    end
  end

  let(:build) { Build.new }
  let(:logger) { double('Logger', debug: nil, error: nil) }

  before do
    allow(build).to receive(:logger).and_return(logger)
  end

  it 'creates a state machine with the expected states' do
    expect(build.states).to contain_exactly("pending", "running", "finishing", "succeeded", "rejected", "failed", "caught")
  end

  it 'attempts to call `send_status` on a transition' do
    expect(build).to receive(:send_status).with(:run, nil)
    build.run
  end

  it "attempts to call an event callback if it's defined on the class only if the transition succeeded" do
    expect(build.run).to eq('some return value')
    expect(build.state).to eq('running')

    expect(build.run).to eq(nil)
  end

end
