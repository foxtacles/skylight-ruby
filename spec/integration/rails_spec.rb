require 'spec_helper'

enable = false
begin
  require 'rails'
  require 'action_controller/railtie'
  require 'skylight/railtie'
  enable = true
rescue LoadError
  puts "[INFO] Skipping rails integration specs"
end

if enable

  describe 'Rails integration' do

    def boot
      MyApp.initialize!

      MyApp.routes.draw do
        resources :users do
          collection do
            get :failure
            get :handled_failure
            get :header
            get :status
            get :no_template
            get :too_many_spans
          end
        end
        get '/metal' => 'metal#show'
      end
    end

    class ControllerError < StandardError; end

    before :each do
      @original_env = ENV.to_hash
      ENV['SKYLIGHT_AUTHENTICATION']       = "lulz"
      ENV['SKYLIGHT_BATCH_FLUSH_INTERVAL'] = "1"
      ENV['SKYLIGHT_REPORT_URL']           = "http://127.0.0.1:#{port}/report"
      ENV['SKYLIGHT_REPORT_HTTP_DEFLATE']  = "false"
      ENV['SKYLIGHT_AUTH_URL']             = "http://127.0.0.1:#{port}/agent"
      ENV['SKYLIGHT_VALIDATION_URL']       = "http://127.0.0.1:#{port}/agent/config"
      ENV['SKYLIGHT_AUTH_HTTP_DEFLATE']    = "false"
      ENV['SKYLIGHT_ENABLE_SEGMENTS']      = "true"

      if ENV['DEBUG']
        ENV['SKYLIGHT_ENABLE_TRACE_LOGS']    = "true"
        ENV['SKYLIGHT_LOG_FILE']             = "-"
      end

      class CustomMiddleware

        def initialize(app)
          @app = app
        end

        def call(env)
          if env["PATH_INFO"] == "/middleware"
            return [200, { }, ["CustomMiddleware"]]
          end

          @app.call(env)
        end

      end

      class NonClosingMiddleware
        def initialize(app)
          @app = app
        end

        def call(env)
          res = @app.call(env)

          # NOTE: We are intentionally throwing away the response without calling close
          # This is to emulate a non-conforming Middleware
          if env["PATH_INFO"] == "/non-closing"
            return [200, { }, ["NonClosing"]]
          end

          res
        end
      end

      class NonArrayMiddleware
        def initialize(app)
          @app = app
        end

        def call(env)
          if env["PATH_INFO"] == "/non-array"
            return Rack::Response.new(["NonArray"])
          end

          @app.call(env)
        end
      end

      class InvalidMiddleware
        def initialize(app)
          @app = app
        end

        def call(env)
          if env["PATH_INFO"] == "/invalid"
            return "Hello"
          end

          @app.call(env)
        end
      end

      class ::MyApp < Rails::Application
        config.secret_key_base = '095f674153982a9ce59914b561f4522a'

        config.active_support.deprecation = :stderr

        config.logger = Logger.new(STDOUT)
        config.logger.level = Logger::DEBUG
        config.logger.progname = "Rails"

        config.eager_load = false

        # Log request ids
        config.log_tags = Rails.version =~ /^4\./ ? [ :uuid ] : [ :request_id ]

        # This class has no name
        config.middleware.use(Class.new do
          def initialize(app)
            @app = app
          end

          def call(env)
            if env["PATH_INFO"] == "/anonymous"
              return [200, { }, ["Anonymous"]]
            end

            @app.call(env)
          end
        end)

        config.middleware.use NonClosingMiddleware
        config.middleware.use NonArrayMiddleware
        config.middleware.use InvalidMiddleware
        config.middleware.use CustomMiddleware

      end

      # We include instrument_method in multiple places to ensure
      # that all of them work.

      class ::UsersController < ActionController::Base
        include Skylight::Helpers

        if respond_to?(:before_action)
          before_action :authorized?
          before_action :set_variant
        else
          before_filter :authorized?
          before_filter :set_variant
        end

        rescue_from 'ControllerError' do |exception|
          render json: { error: exception.message }, status: 500
        end

        def index
          Skylight.instrument category: 'app.inside' do
            if Rails.version =~ /^4\./
              render text: "Hello"
            else
              render plain: "Hello"
            end
            Skylight.instrument category: 'app.zomg' do
              # nothing
            end
          end
        end
        instrument_method :index

        instrument_method
        def show
          respond_to do |format|
            format.json do |json|
              json.tablet { render json: { hola_tablet: params[:id] } }
              json.none   { render json: { hola: params[:id] } }
            end
            format.html do
              if Rails.version =~ /^4\./
                render text: "Hola: #{params[:id]}"
              else
                render plain: "Hola: #{params[:id]}"
              end
            end
          end
        end

        def failure
          raise "Fail!"
        end

        def handled_failure
          raise ControllerError, "Handled!"
        end

        def header
          Skylight.instrument category: 'app.zomg' do
            head 200
          end
        end

        def status
          s = params[:status] || 200
          if Rails.version =~ /^4\./
            render text: s, status: s
          else
            render plain: s, status: s
          end
        end

        def no_template
          # This action has no template to auto-render
        end

        def too_many_spans
          # Max is 2048
          2050.times do
            Skylight.instrument category: 'app.zomg' do
              # nothing
            end
          end
          if Rails.version =~ /^4\./
            render text: "There's too many of them!"
          else
            render plain: "There's too many of them!"
          end
        end

        private

          def authorized?
            true
          end

          # It's important for us to test a method ending in a special char
          instrument_method :authorized?, title: "Check authorization"

          def set_variant
            request.variant = :tablet if params[:tablet]
          end

      end

      class ::MetalController < ActionController::Metal
        include ActionController::Instrumentation

        def show
          render({
            status: 200,
            text: "Zomg!"
          })
        end

        def render(options={})
          self.status = options[:status] || 200
          self.content_type = options[:content_type] || 'text/html; charset=utf-8'
          self.headers['Content-Length'] = options[:text].bytesize.to_s
          self.response_body = options[:text]
        end
      end
    end

    after :each do
      MyApp.config.skylight.middleware_position = 0

      ENV.replace(@original_env)

      Skylight.stop!

      # Clean slate
      # It's really too bad we can't run RSpec tests in a fork
      Object.send(:remove_const, :MyApp)
      Object.send(:remove_const, :UsersController)
      Object.send(:remove_const, :MetalController)
      Rails::Railtie::Configuration.class_variable_set(:@@app_middleware, nil)
      Rails.application = nil
    end

    shared_examples "with agent" do

      context "configuration" do

        it "sets log file" do
          expect(Skylight.instrumenter.config['log_file']).to eq(MyApp.root.join('log/skylight.log').to_s)
        end

        context "on heroku" do

          def pre_boot
            ENV['SKYLIGHT_HEROKU_DYNO_INFO_PATH'] = File.expand_path('../../../skylight-core/spec/support/heroku_dyno_info_sample', __FILE__)
          end

          it "recognizes heroku" do
            expect(Skylight.instrumenter.config).to be_on_heroku
          end

          it "leaves log file as STDOUT" do
            expect(Skylight.instrumenter.config['log_file']).to eq('-')
          end

        end

      end

      it 'successfully calls into rails' do
        res = call MyApp, env('/users')
        expect(res).to eq(["Hello"])

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        segment = Rails.version =~ /^4\./ ? 'html' : 'text'
        expect(endpoint.name).to eq("UsersController#index<sk-segment>#{segment}</sk-segment>")
        expect(endpoint.traces.count).to eq(1)
        trace = endpoint.traces[0]

        app_spans = trace.spans.map{|s| [s.event.category, s.event.title] }.select{|s| s[0] =~ /^app./ }
        expect(app_spans).to eq([
          ["app.rack.request", nil],
          ["app.controller.request", "UsersController#index"],
          ["app.method", "Check authorization"],
          ["app.method", "UsersController#index"],
          ["app.inside", nil],
          ["app.zomg", nil]
        ])
      end

      it 'successfully instruments middleware', :middleware_probe do
        call MyApp, env('/users')
        server.wait resource: '/report'

        trace = server.reports[0].endpoints[0].traces[0]

        app_and_rack_spans = trace.spans.map{|s| [s.event.category, s.event.title] }.select{|s| s[0] =~ /^(app|rack)./ }

        # We know the first one
        expect(app_and_rack_spans[0]).to eq(["app.rack.request", nil])

        # But the middlewares will be variable, depending on the Rails version
        count = 0
        while true do
          break if app_and_rack_spans[count+1][0] != "rack.middleware"
          count += 1
        end

        # We should have at least 2, but in reality a lot more
        expect(count).to be > 2

        # This one should be in all versions
        expect(app_and_rack_spans).to include(["rack.middleware", "Anonymous Middleware"], ["rack.middleware", "CustomMiddleware"])

        # Check the rest
        expect(app_and_rack_spans[(count+1)..-1]).to eq([
          ["rack.app", "ActionDispatch::Routing::RouteSet"],
          ["app.controller.request", "UsersController#index"],
          ["app.method", "Check authorization"],
          ["app.method", "UsersController#index"],
          ["app.inside", nil],
          ["app.zomg", nil]
        ])
      end

      it 'successfully names requests handled by middleware', :middleware_probe do
        res = call MyApp, env('/middleware')
        expect(res).to eq(["CustomMiddleware"])

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        expect(endpoint.name).to eq("CustomMiddleware")
      end

      it 'successfully names requests handled by anonymous middleware', :middleware_probe do
        res = call MyApp, env('/anonymous')
        expect(res).to eq(["Anonymous"])

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        expect(endpoint.name).to eq("Anonymous Middleware")
      end

      context "with middleware_position" do

        def pre_boot
          MyApp.config.skylight.middleware_position = { after: CustomMiddleware }
        end

        it 'does not instrument middleware if Skylight position is after', :middleware_probe do
          call MyApp, env('/users')
          server.wait resource: '/report'

          trace = server.reports[0].endpoints[0].traces[0]

          titles = trace.spans.map{ |s| s.event.title }

          # If Skylight runs after CustomMiddleware, we shouldn't see it
          expect(titles).to_not include("CustomMiddleware")
        end

      end

      context "middleware that don't conform to Rack SPEC" do

        after :each do
          Skylight::Core::Probes::Middleware::Probe.enable!
        end

        it "doesn't report middleware that don't close body", :middleware_probe do
          ENV['SKYLIGHT_RAISE_ON_ERROR'] = nil

          expect_any_instance_of(Skylight::Core::Instrumenter).to_not receive(:process)

          call MyApp, env('/non-closing')
        end

        it "disables probe when middleware don't close body", :middleware_probe do
          ENV['SKYLIGHT_RAISE_ON_ERROR'] = nil

          call MyApp, env('/non-closing')

          expect(Skylight::Core::Probes::Middleware::Probe).to be_disabled
        end

        it "handles middleware that returns a non-array that is coercable", :middleware_probe do
          ENV['SKYLIGHT_RAISE_ON_ERROR'] = nil

          call MyApp, env('/non-array')
          server.wait resource: '/report'

          trace = server.reports[0].endpoints[0].traces[0]

          titles = trace.spans.map{ |s| s.event.title }

          expect(titles).to include("NonArrayMiddleware")
        end

      end

      context 'with too many spans' do

        context 'with reporting turned on' do

          def pre_boot
            ENV['SKYLIGHT_REPORT_MAX_SPANS_EXCEEDED'] = 'true'
          end

          it 'handles too many spans' do
            segment = Rails.version =~ /^4\./ ? 'html' : 'text'

            expect_any_instance_of(Skylight::Trace).to receive(:error).
                with(/\[E%04d\].+endpoint=%s/, 3, "UsersController#too_many_spans<sk-segment>#{segment}</sk-segment>")

            res = call MyApp, env('/users/too_many_spans')

            server.wait resource: '/report'

            batch = server.reports[0]
            expect(batch).to_not be nil
            expect(batch.endpoints.count).to eq(1)
            endpoint = batch.endpoints[0]

            expect(endpoint.name).to eq("UsersController#too_many_spans<sk-segment>#{segment}</sk-segment>")
            expect(endpoint.traces.count).to eq(1)
            trace = endpoint.traces[0]

            spans = trace.spans.map{|s| [s.event.category, s.event.title] }

            expect(spans).to eq([["app.rack.request", nil],
                                  ["error.code.3", nil]])
          end

        end

        context 'without reporting' do

          it 'handles too many spans' do
            ENV['SKYLIGHT_RAISE_ON_ERROR'] = nil

            expect_any_instance_of(Skylight::Instrumenter).to_not receive(:process)

            call MyApp, env('/users/too_many_spans')
          end

        end

      end

      it 'sets correct segment' do
        res = call MyApp, env('/users/1.json')
        expect(res).to eq([{ hola: '1' }.to_json])

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#show<sk-segment>json</sk-segment>")
      end

      it 'sets rendered segment, not requested' do
        res = call MyApp, env('/users/1', 'HTTP_ACCEPT' => '*/*')
        expect(res).to eq([{ hola: '1' }.to_json])

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#show<sk-segment>json</sk-segment>")
      end

      it 'sets correct segment for exceptions' do
        # Turn off for this test, since it will log a ton, due to the mock
        ENV['SKYLIGHT_RAISE_ON_ERROR'] = nil

        # TODO: This native_span_set_exception stuff should probably get its own test
        # NOTE: This tests handling by the Subscriber. The Middleware probe may catch the exception again.
        args = [anything]
        args << (Rails::VERSION::MAJOR >= 5 ? an_instance_of(RuntimeError) : nil)
        args << ["RuntimeError", "Fail!"]

        allow_any_instance_of(Skylight::Trace).to \
          receive(:native_span_set_exception).and_call_original

        expect_any_instance_of(Skylight::Trace).to \
          receive(:native_span_set_exception).with(*args).once.and_call_original

        res = call MyApp, env('/users/failure')
        expect(res).to be_empty

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#failure<sk-segment>error</sk-segment>")
      end

      it 'sets correct segment for handled exceptions' do
        status, headers, body = call_full MyApp, env('/users/handled_failure')
        expect(status).to eq(500)
        expect(body).to eq([{ error: "Handled!" }.to_json])

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        expect(endpoint.name).to eq("UsersController#handled_failure<sk-segment>error</sk-segment>")
      end

      it 'sets correct segment for `head`' do
        status, headers, body = call_full MyApp, env('/users/header')
        expect(status).to eq(200)
        expect(body[0].strip).to eq('') # Some Rails versions have a space, some don't

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        expect(endpoint.name).to eq("UsersController#header")

        expect(endpoint.traces.count).to eq(1)
        trace = endpoint.traces[0]
        names = trace.spans.map { |s| s.event.category }

        expect(names.length).to be >= 3
        expect(names).to include('app.zomg')
        expect(names[0]).to eq('app.rack.request')
      end

      it 'sets correct segment for 4xx responses' do
        status, headers, body = call_full MyApp, env('/users/status?status=404')
        expect(status).to eq(404)
        expect(body).to eq(['404'])

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#status<sk-segment>error</sk-segment>")
      end

      it 'sets correct segment for 5xx responses' do
        status, headers, body = call_full MyApp, env('/users/status?status=500')
        expect(status).to eq(500)
        expect(body).to eq(['500'])

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#status<sk-segment>error</sk-segment>")
      end

      it 'sets correct segment when no template is found' do
        status, headers, body = call_full MyApp, env('/users/no_template')

        if Rails.version =~ /^4\./
          expect(status).to eq(500)
        else
          expect(status).to eq(406)
        end

        expect(body[0]).to be_blank

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#no_template<sk-segment>error</sk-segment>")
      end

      it 'sets correct segment with variant' do
        res = call MyApp, env('/users/1.json?tablet=1')
        expect(res).to eq([{ hola_tablet: '1' }.to_json])

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#show<sk-segment>json+tablet</sk-segment>")
      end

      it 'sets correct segment for `head` with variant' do
        status, headers, body = call_full MyApp, env('/users/header?tablet=1', 'HTTP_ACCEPT' => 'application/json')
        expect(status).to eq(200)
        expect(body[0].strip).to eq('') # Some Rails versions have a space, some don't

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#header")
      end

      it 'can instrument metal controllers' do
        call MyApp, env('/metal')

        server.wait resource: '/report'

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("MetalController#show<sk-segment>html</sk-segment>")
        expect(endpoint.traces.count).to eq(1)
        trace = endpoint.traces[0]

        names = trace.spans.map { |s| s.event.category }

        expect(names.length).to be >= 1
        expect(names[0]).to eq('app.rack.request')
      end

    end

    context "activated from application.rb", :http, :agent do

      def pre_boot
      end

      before :each do
        @original_environments = MyApp.config.skylight.environments.clone
        MyApp.config.skylight.environments << 'development'

        stub_config_validation
        stub_session_request

        pre_boot
        boot
      end

      after :each do
        MyApp.config.skylight.environments = @original_environments
      end

      it_behaves_like 'with agent'
    end

    context "activated from ENV", :http, :agent do

      def pre_boot
      end

      before :each do
        ENV['SKYLIGHT_ENABLED'] = "true"

        stub_config_validation
        stub_session_request

        pre_boot
        boot
      end

      it_behaves_like 'with agent'
    end

    shared_examples "without agent" do

      before :each do
        # Sanity check that we are indeed running without an active agent
        expect(Skylight.instrumenter).to be_nil
      end

      it "allows calls to Skylight.instrument" do
        expect(call(MyApp, env('/users'))).to eq(["Hello"])
      end

      it "supports Skylight::Helpers" do
        expect(call(MyApp, env('/users/1'))).to eq(["Hola: 1"])
      end

    end

    context "without configuration" do
      before :each do
        boot
      end

      it_behaves_like 'without agent'
    end

    context "deactivated from ENV" do
      def pre_boot
      end

      before :each do
        ENV['SKYLIGHT_ENABLED'] = "false"

        @original_environments = MyApp.config.skylight.environments.clone
        MyApp.config.skylight.environments << 'development'

        pre_boot
        boot
      end

      after :each do
        MyApp.config.skylight.environments = @original_environments
      end

      it_behaves_like 'without agent'
    end


    def call_full(app, env)
      resp = app.call(env)
      consume(resp)
      resp
    end

    def call(app, env)
      call_full(app, env)[2]
    end

    def env(path = '/', opts = {})
      Rack::MockRequest.env_for(path, opts)
    end

    def consume(resp)
      data = []
      resp[2].each{|p| data << p }
      resp[2].close if resp[2].respond_to?(:close)
      resp[2] = data
      resp
    end

  end
end
