helm-dir := source_directory()
helm-image := "aim-helm"

# Build the isolated development image.
@build:
    docker build --tag {{ helm-image }} {{ helm-dir }}

# Run the gem specs.
[positional-arguments]
@spec *args: build
    docker run --rm {{ helm-image }} bundle exec rspec "$@"

# Lint the gem.
[positional-arguments]
@rubocop *args: build
    docker run --rm {{ helm-image }} bundle exec rubocop "$@"

# Autocorrect the gem while mounting its source back into the workspace.
[positional-arguments]
@rubocop-fix *args: build
    docker run --rm --volume "{{ helm-dir }}:/aim_helm" {{ helm-image }} bundle exec rubocop -A "$@"

# Exercise a real OpenAI stream with credentials from an env file.
@live-openai env-file=(invocation_directory() / ".env"): build
    docker run --rm --env-file "{{ env-file }}" -e AIM_HELM_LIVE=1 {{ helm-image }} bundle exec rspec spec/live_spec.rb --example gpt-5.6-luna

# Exercise a real Anthropic stream with credentials from an env file.
@live-anthropic env-file=(invocation_directory() / ".env"): build
    docker run --rm --env-file "{{ env-file }}" -e AIM_HELM_LIVE=1 {{ helm-image }} bundle exec rspec spec/live_spec.rb --example claude-opus-5
