require "unit_spec_helper"

describe Rpush::Daemon::Feeder do
  let!(:app) { Rpush::Apns::App.create!(name: 'my_app', environment: 'development', certificate: TEST_CERT) }
  let(:notification) { Rpush::Apns::Notification.create!(device_token: "a" * 64, app: app) }
  let(:logger) { double }
  let(:interruptible_sleep) { double(sleep: nil, stop: nil, start: nil) }
  let(:store) do double(Rpush::Daemon::Store::ActiveRecord,
                        deliverable_notifications: [notification], release_connection: nil)
  end

  before do
    Rpush.configure do |config|
      config.batch_size = 5000
      config.push_poll = 0
      config.embedded = false
      config.push = false
    end
    Rpush.stub(logger: logger)
    Rpush::Daemon.stub(store: store)
    Rpush::Daemon::Feeder.stub(should_stop: true)
    Rpush::Daemon::AppRunner.stub(enqueue: nil, cumulative_queue_size: 0)
    Rpush::Daemon::InterruptibleSleep.stub(new: interruptible_sleep)
  end

  def start_and_stop
    Rpush::Daemon::Feeder.start
    Rpush::Daemon::Feeder.stop
  end

  it 'starts the loop in a new thread if embedded' do
    Rpush.config.embedded = true
    Thread.should_receive(:new).and_yield
    Rpush::Daemon::Feeder.should_receive(:feed_forever)
    start_and_stop
  end

  it 'loads deliverable notifications' do
    Rpush::Daemon.store.should_receive(:deliverable_notifications).with(Rpush.config.batch_size)
    start_and_stop
  end

  it 'does not load more notifications if the cumulative queue size is equal to the batch size' do
    Rpush::Daemon::AppRunner.stub(cumulative_queue_size: Rpush.config.batch_size)
    Rpush::Daemon.store.should_not_receive(:deliverable_notifications)
    start_and_stop
  end

  it 'limits the batch size if some runners are still processing notifications' do
    Rpush.config.stub(batch_size: 10)
    Rpush::Daemon::AppRunner.stub(cumulative_queue_size: 6)
    Rpush::Daemon.store.should_receive(:deliverable_notifications).with(4)
    start_and_stop
  end

  it 'enqueues notifications without looping if in push mode' do
    Rpush.config.push = true
    Rpush::Daemon::Feeder.should_not_receive(:feed_forever)
    Rpush::Daemon::Feeder.should_receive(:enqueue_notifications)
    start_and_stop
  end

  it "enqueues the notifications" do
    Rpush::Daemon::AppRunner.should_receive(:enqueue).with([notification])
    start_and_stop
  end

  it "logs errors" do
    e = StandardError.new("bork")
    Rpush::Daemon.store.stub(:deliverable_notifications).and_raise(e)
    Rpush.logger.should_receive(:error).with(e)
    start_and_stop
  end

  describe 'stop' do
    it 'interrupts sleep' do
      interruptible_sleep.should_receive(:stop)
      start_and_stop
    end

    it 'releases the store connection' do
      Rpush::Daemon.store.should_receive(:release_connection)
      start_and_stop
    end
  end

  it 'enqueues notifications when started' do
    Rpush::Daemon::Feeder.should_receive(:enqueue_notifications).at_least(:once)
    Rpush::Daemon::Feeder.stub(:loop).and_yield
    start_and_stop
  end

  it 'sleeps' do
    interruptible_sleep.should_receive(:sleep)
    start_and_stop
  end

  describe 'wakeup' do
    it 'interrupts sleep' do
      interruptible_sleep.should_receive(:wakeup)
      Rpush::Daemon::Feeder.start
      Rpush::Daemon::Feeder.wakeup
    end

    after { Rpush::Daemon::Feeder.stop }
  end
end
