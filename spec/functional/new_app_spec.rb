require 'functional_spec_helper'

describe 'New app loading' do
  TIMEOUT = 10

  let(:app) { create_app }
  let(:notification) { create_notification }
  let(:tcp_socket) { double(TCPSocket, setsockopt: nil, close: nil) }
  let(:ssl_socket) do double(OpenSSL::SSL::SSLSocket, :sync= => nil, connect: nil,
                                                      write: nil, flush: nil, read: nil, close: nil)
  end
  let(:io_double) { double(select: nil) }

  before do
    stub_tcp_connection
  end

  def create_app
    app = Rpush::Apns::App.new
    app.certificate = TEST_CERT
    app.name = 'test'
    app.environment = 'sandbox'
    app.save!
    app
  end

  def create_notification
    notification = Rpush::Apns::Notification.new
    notification.app = app
    notification.alert = 'test'
    notification.device_token = 'a' * 64
    notification.save!
    notification
  end

  def stub_tcp_connection
    Rpush::Daemon::TcpConnection.any_instance.stub(connect_socket: [tcp_socket, ssl_socket])
    Rpush::Daemon::TcpConnection.any_instance.stub(setup_ssl_context: double.as_null_object)
    stub_const('Rpush::Daemon::TcpConnection::IO', io_double)
  end

  def wait_for_notification_to_deliver(notification)
    Timeout.timeout(TIMEOUT) do
      until notification.delivered
        sleep 0.1
        notification.reload
      end
    end
  end

  it 'delivers a notification successfully' do
    Rpush.embed
    sleep 1 # wait to boot. this sucks.
    wait_for_notification_to_deliver(notification)
  end

  after { Timeout.timeout(TIMEOUT) { Rpush.shutdown } }
end
