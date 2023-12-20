FROM ruby:bullseye
WORKDIR /usr/local/src

RUN git clone https://github.com/ggerganov/whisper.cpp && \
    cd whisper.cpp && \
    bash ./models/download-ggml-model.sh base && \
    make && \
    mkdir -p /opt/whisper && \
    mv main /opt/whisper/ && \
    mv models /opt/whisper/models

RUN apt update -qqy && \
  apt install -qqy ffmpeg && \
  apt clean -qqy && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /opt/tamaki
COPY Gemfile Gemfile.lock /opt/tamaki/
RUN bundle install

COPY . /opt/tamaki
CMD bundle exec puma
