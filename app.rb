require 'sinatra'
require 'sinatra/contrib'
require 'tmpdir'
require 'json'
require 'sidekiq/api'
require 'sidekiq-status'
require './worker'

Sidekiq.configure_client do |config|
  Sidekiq::Status.configure_client_middleware config, expiration: 3600
  config.redis = { url: ENV['REDIS_URL'] || 'redis://localhost:6379', db: ENV['REDIS_DB'] || 1 }
end

class WebApp < Sinatra::Base
  enable :sessions
  configure :development do
    register Sinatra::Reloader
  end

  def redis
    @redis ||= Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379', db: ENV['REDIS_DB'] || 1)
  end

  post '/upload' do
    unless params[:file] && (tmpfile = params[:file][:tempfile]) && (name = params[:file][:filename])
      return 'No file selected'
    end

    ext = File.extname(name)
    tmpdir = Dir.tmpdir
    path = File.join(tmpdir, "upload-#{Time.now.strftime('%Y%m%d%H%M%S')}#{ext}")
    begin
      File.open(path, 'wb') do |f|
        while chunk = tmpfile.read(1024 * 1024 * 4) # 4MB のチャンクサイズ
          f.write(chunk)
        end
      end

      # データストアを使いたくないので、同じホストで動いているSidekiqにジョブを投げる
      job_id = JobWorker.set(queue: ENV['HOSTNAME'] || `hostname`.strip).perform_async(tmpdir, path)
      session[:job_id] = job_id
      content_type :json
      { job_id: job_id }.to_json
    rescue StandardError => e
      { error: e.message }.to_json
    end
  end
  get '/status/:job_id' do
    result = nil
    job_status = Sidekiq::Status.status(params[:job_id])
    if job_status == :complete
      result = redis.get("job_#{params[:job_id]}_result")
      session[:job_id] = nil
    end
    { status: job_status, result: result }.to_json
  end

  get '/' do
    if session[:job_id]
      status = Sidekiq::Status.status(session[:job_id])
      @job_id = if %i[working queued retrying].include?(status)
                  session[:job_id]
                else
                  session[:job_id] = nil
                end
    end
    erb :index
  end
end
