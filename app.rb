require 'sinatra'
require 'sinatra/contrib'
require 'tempfile'
require 'json'
require 'shellwords'
require 'openai'

set :public_folder, 'public'

class WebApp < Sinatra::Base
  configure :development do
    register Sinatra::Reloader
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
    4. 結果はHTMLでユーザーに表示するので、改行は<br>タグを入れてください
    5. 誤字、脱字については修正、加筆して下さい
    6. 結果はマークダウンで出力してください。
    7. 出力は```のようなテンプレートリテラルで囲まないでください。

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

  post '/upload' do
    unless params[:file] && (tmpfile = params[:file][:tempfile]) && (name = params[:file][:filename])
      return 'No file selected'
    end

    ext = File.extname(name)
    tempfile = Tempfile.new(['uploaded_', ext])
    begin
      path = tempfile.path
      File.open(path, 'wb') do |f|
        f.write(tmpfile.read)
      end

      text = convert_audio_to_text(path, path)
      summary = summarize_text(text)

      content_type :json
      { summary: summary }.to_json
    rescue StandardError => e
      { error: e.message }.to_json
    ensure
      tempfile.close
      tempfile.unlink
    end
  end

  get '/' do
    send_file 'public/index.html'
  end
end
