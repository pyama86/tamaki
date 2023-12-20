require 'sidekiq'
require 'shellwords'
require 'openai'
require 'redis'
require 'fileutils'
require 'sidekiq-status'

Sidekiq.configure_server do |config|
  Sidekiq::Status.configure_server_middleware config, expiration: 3600
  config.redis = { url: ENV['REDIS_URL'] || 'redis://localhost:6379', db: ENV['REDIS_DB'] || 1 }
end
class JobWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker
  sidekiq_options retry: 3
  sidekiq_options queue: ENV['HOSTNAME'] || `hostname`.strip
  def redis
    @redis ||= Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379', db: ENV['REDIS_DB'] || 1)
  end

  def convert_audio_to_text(audio_path, output_path)
    system("ffmpeg -i #{::Shellwords.escape(audio_path)} -ar 16000 -ac 1 -c:a pcm_s16le #{::Shellwords.escape(output_path)}.wav")
    system("#{(ENV['WHISPER_PATH'] && ::File.join(ENV['WHISPER_PATH'],
                                                  'main')) || './main'} -l ja -t 4 -m #{(ENV['WHISPER_PATH'] && ::File.join(ENV['WHISPER_PATH'],
                                                                                                                            'models')) || './models'}/ggml-base.bin -otxt #{::Shellwords.escape(output_path)}.txt #{::Shellwords.escape(output_path)}.wav")

    File.read("#{output_path}.wav.txt")
  end

  def client
    raise 'OPENAI_API_KEY is not set' unless ENV['OPENAI_API_KEY']

    @client ||= ::OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
  end

  def summarize_text(text)
    question = <<-QUESTION
    あなたに、whisperで自動で書き起こしした文章を渡します。下記の要件の通りに、文章を要約してください。

    1. 議事録として、もれなく要点を抑えていること
    2. あなたの言葉で、文章を要約してください
    3. 適切に段落を分けて、適宜見出しをつけてください
    4. 誤字、脱字については修正、加筆して下さい
    5. 結果はマークダウンで出力してください。
    6. 出力は```のようなテンプレートリテラルで囲まないでください。

    ## テキスト
    #{text}
    QUESTION

    response = client.chat(
      parameters: {
        model: ENV['OPENAI_MODEL'] || 'gpt-4-1106-preview',
        messages: [{ role: 'user', content: question }],
        temperature: 0.7
      }
    )

    response.dig('choices', 0, 'message', 'content')
  end

  def perform(dir, path)
    text = convert_audio_to_text(path, path)
    summary = summarize_text(text)
    redis.multi do
      redis.set("job_#{jid}_result", summary)
      redis.expire("job_#{jid}_result", 300)
    end

    FileUtils.rm_rf(dir)
  end
end
