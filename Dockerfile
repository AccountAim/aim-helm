# syntax=docker/dockerfile:1.7

FROM ruby:3.4-alpine

ENV BUNDLE_JOBS=4 \
    BUNDLE_RETRY=5 \
    BUNDLE_NO_CACHE=1 \
    BUNDLE_SILENCE_ROOT_WARNING=1

RUN apk add --no-cache build-base

WORKDIR /aim_helm

COPY Gemfile Gemfile.lock aim-helm.gemspec ./
RUN bundle install

COPY . ./

CMD ["bundle", "exec", "rspec"]
